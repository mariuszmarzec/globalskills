#!/bin/bash
# workspace-manager.sh: Manages workspace leasing for concurrency
#
# Provides functions for:
# - Creating and managing a pool of isolated workspaces
# - Leasing workspaces to tasks for exclusive access
# - Releasing workspaces back to the pool
# - Cleaning up broken workspaces

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
WORKSPACES_DIR="$MANUL_WORKSPACE"

: "${PID_FILE:=/dev/null}"
get_daemon_pid() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
    echo "$pid"
  else
    echo "0"
  fi
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

workspace_init() {
  mkdir -p "$WORKSPACES_DIR"
  sqlite3 "$DB" "
    CREATE TABLE IF NOT EXISTS workspaces (
      workspaceId TEXT PRIMARY KEY,
      workspacePath TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'IDLE',
      currentTaskId TEXT,
      lastUsedAt TEXT
    );
    CREATE TABLE IF NOT EXISTS workspace_contexts (
      contextId TEXT PRIMARY KEY,
      parentContextId TEXT,
      workspaceId TEXT NOT NULL,
      repository TEXT,
      prNumber INTEGER,
      createdAt TEXT NOT NULL DEFAULT (datetime('now')),
      lastUsedAt TEXT NOT NULL DEFAULT (datetime('now'))
    );
  "
}

workspace_pool_init() {
  local pool_size="${1:-$((MAX_CONCURRENT_TASKS / 1))}"
  local reset="${2:-}"
  workspace_init
  if [ "$reset" = "reset" ]; then
    sqlite3 "$DB" "DELETE FROM workspace_contexts; DELETE FROM workspaces;" 2>/dev/null || true
  fi
  local current_size
  current_size="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces;" 2>/dev/null || echo 0)"
  local i
  for ((i = current_size; i < pool_size; i++)); do
    local ws_id="ws-$i-$(date +%s)"
    local ws_path="$WORKSPACES_DIR/$ws_id"
    mkdir -p "$ws_path"
    sqlite3 "$DB" "INSERT OR IGNORE INTO workspaces(workspaceId, workspacePath, status, lastUsedAt) VALUES('$ws_id', '$ws_path', 'IDLE', datetime('now'));"
  done
}

workspace_lease() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local result
  result="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; UPDATE workspaces SET status='BUSY', currentTaskId='$safe_task_id', lastUsedAt=datetime('now') WHERE workspaceId IN (SELECT w.workspaceId FROM workspaces w WHERE w.status='IDLE' AND NOT EXISTS (SELECT 1 FROM workspace_contexts wc WHERE wc.workspaceId=w.workspaceId) LIMIT 1); SELECT changes(); COMMIT;" 2>/dev/null)"
  result="$(printf '%s\n' "$result" | tail -n1)"
  if [ "${result:-0}" -eq 0 ] || [ -z "$result" ]; then
    return 1
  fi
  sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null
}

workspace_release() {
  local ws_id="$1"
  local task_id="${2:-}"
  local safe_ws_id
  safe_ws_id="$(sql_escape "$ws_id")"
  local owns
  owns="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$safe_ws_id' AND status='BUSY';" 2>/dev/null)"
  if [ "${owns:-0}" -eq 0 ]; then
    return 1
  fi
  if [ -n "$task_id" ]; then
    local safe_task_id
    safe_task_id="$(sql_escape "$task_id")"
    local correct_owner
    correct_owner="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id';" 2>/dev/null)"
    if [ "${correct_owner:-0}" -eq 0 ]; then
      return 1
    fi
  fi
  # Refresh the idle timestamp on every release so a legitimately reused
  # workspace is not mistaken for an abandoned idle workspace by stale cleanup.
  sqlite3 "$DB" "UPDATE workspaces SET status='IDLE', currentTaskId=NULL, lastUsedAt=datetime('now') WHERE workspaceId='$safe_ws_id';"
}

# Atomically reclaim a previously-used workspace for a task whose processed_comments row points to it.
workspace_reclaim() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local ws_id
  ws_id="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null)"
  [ -n "$ws_id" ] || return 1
  local safe_ws_id
  safe_ws_id="$(sql_escape "$ws_id")"
  local result
  result="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; UPDATE workspaces SET status='BUSY', currentTaskId='$safe_task_id', lastUsedAt=datetime('now') WHERE workspaceId='$safe_ws_id' AND (status='IDLE' OR (status='BUSY' AND currentTaskId='$safe_task_id')); SELECT changes(); COMMIT;" 2>/dev/null)"
  result="$(printf '%s\n' "$result" | tail -n1)"
  if [ "${result:-0}" -ne 1 ] || [ -z "$result" ]; then
    return 1
  fi
  sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null
}


workspace_claim_id() {
  local ws_id="$1"
  local task_id="$2"
  local safe_ws_id safe_task_id
  safe_ws_id="$(sql_escape "$ws_id")"
  safe_task_id="$(sql_escape "$task_id")"
  local result
  result="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; UPDATE workspaces SET status='BUSY', currentTaskId='$safe_task_id', lastUsedAt=datetime('now') WHERE workspaceId='$safe_ws_id' AND (status='IDLE' OR (status='BUSY' AND currentTaskId='$safe_task_id')); SELECT changes(); COMMIT;" 2>/dev/null)"
  result="$(printf '%s\n' "$result" | tail -n1)"
  [ "${result:-0}" -eq 1 ] || return 1
}

# Acquire a workspace for a logical context (PR or review thread).
#
# Resolution order:
#   1. Exact context mapping (same thread / same PR)
#   2. Parent context mapping (review thread -> PR)
#   3. A fresh unbound workspace
#
# Return codes:
#   0 = acquired, stdout contains workspaceId
#   1 = no workspace currently available
#   2 = context workspace exists but is busy with another task
workspace_context_acquire() {
  local task_id="$1"
  local context_id="$2"
  local parent_context_id="${3:-}"
  local repository="${4:-}"
  local pr_number="${5:-}"

  [ -n "$task_id" ] || return 1
  [ -n "$context_id" ] || return 1

  local safe_context_id safe_parent_id safe_repo
  safe_context_id="$(sql_escape "$context_id")"
  safe_parent_id="$(sql_escape "$parent_context_id")"
  safe_repo="$(sql_escape "$repository")"

  local mapped_ws
  mapped_ws="$(sqlite3 "$DB" "SELECT workspaceId FROM workspace_contexts WHERE contextId='$safe_context_id' LIMIT 1;" 2>/dev/null || true)"

  if [ -n "$mapped_ws" ]; then
    if workspace_claim_id "$mapped_ws" "$task_id"; then
      sqlite3 "$DB" "UPDATE workspace_contexts SET lastUsedAt=datetime('now') WHERE contextId='$safe_context_id';" 2>/dev/null || true
      printf '%s\n' "$mapped_ws"
      return 0
    fi
    return 2
  fi

  if [ -n "$parent_context_id" ]; then
    local parent_ws
    parent_ws="$(sqlite3 "$DB" "SELECT workspaceId FROM workspace_contexts WHERE contextId='$safe_parent_id' LIMIT 1;" 2>/dev/null || true)"
    if [ -n "$parent_ws" ]; then
      if workspace_claim_id "$parent_ws" "$task_id"; then
        sqlite3 "$DB" "
          INSERT OR IGNORE INTO workspace_contexts(contextId,parentContextId,workspaceId,repository,prNumber,createdAt,lastUsedAt)
          VALUES('$safe_context_id','$safe_parent_id','$(sql_escape "$parent_ws")','$safe_repo',${pr_number:-NULL},datetime('now'),datetime('now'));
        " 2>/dev/null || true
        printf '%s\n' "$parent_ws"
        return 0
      fi
      return 2
    fi
  fi

  local ws_id
  ws_id="$(workspace_lease "$task_id" 2>/dev/null || true)"
  if [ -z "$ws_id" ]; then
    return 1
  fi

  if ! sqlite3 "$DB" "
    INSERT OR REPLACE INTO workspace_contexts(
      contextId,parentContextId,workspaceId,repository,prNumber,createdAt,lastUsedAt
    )
    VALUES(
      '$safe_context_id',
      NULLIF('$safe_parent_id',''),
      '$(sql_escape "$ws_id")',
      '$safe_repo',
      ${pr_number:-NULL},
      datetime('now'),
      datetime('now')
    );
  " 2>/dev/null; then
    workspace_release "$ws_id" "$task_id" >/dev/null 2>&1 || true
    return 1
  fi

  printf '%s\n' "$ws_id"
}

# Prepare a PR workspace without destroying local/unpushed work.
workspace_prepare_pr_branch() {
  local workdir="$1"
  local branch="$2"

  [ -d "$workdir/.git" ] || return 1
  [ -n "$branch" ] || return 1

  git -C "$workdir" fetch origin "$branch" >/dev/null 2>&1 || return 1

  local current_branch
  current_branch="$(git -C "$workdir" symbolic-ref --short HEAD 2>/dev/null || true)"
  local dirty
  dirty="$(git -C "$workdir" status --porcelain 2>/dev/null || true)"

  if [ "$current_branch" != "$branch" ]; then
    if [ -n "$dirty" ]; then
      echo "workspace_prepare_pr_branch: refusing branch switch in dirty workspace (current=$current_branch expected=$branch)" >&2
      return 2
    fi

    if git -C "$workdir" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$workdir" checkout "$branch" >/dev/null 2>&1 || return 1
    else
      git -C "$workdir" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1 || return 1
    fi
  fi

  dirty="$(git -C "$workdir" status --porcelain 2>/dev/null || true)"
  if [ -z "$dirty" ]; then
    local local_head remote_head
    local_head="$(git -C "$workdir" rev-parse HEAD 2>/dev/null || true)"
    remote_head="$(git -C "$workdir" rev-parse "origin/$branch" 2>/dev/null || true)"
    if [ -n "$local_head" ] && [ -n "$remote_head" ] && [ "$local_head" != "$remote_head" ]; then
      if git -C "$workdir" merge-base --is-ancestor "$local_head" "$remote_head" 2>/dev/null; then
        git -C "$workdir" merge --ff-only "$remote_head" >/dev/null 2>&1 || return 1
      else
        echo "workspace_prepare_pr_branch: preserving local commits (local=$local_head remote=$remote_head)" >&2
      fi
    fi
  else
    echo "workspace_prepare_pr_branch: preserving dirty workspace $workdir" >&2
  fi

  [ "$(git -C "$workdir" symbolic-ref --short HEAD 2>/dev/null)" = "$branch" ]
}

workspace_mark_broken() {
  local ws_id="$1"
  local safe_ws_id
  safe_ws_id="$(sql_escape "$ws_id")"
  sqlite3 "$DB" "DELETE FROM workspace_contexts WHERE workspaceId='$safe_ws_id';" 2>/dev/null || true
  sqlite3 "$DB" "UPDATE workspaces SET status='BROKEN' WHERE workspaceId='$safe_ws_id';"
  rm -rf "$WORKSPACES_DIR/$ws_id"
}

workspace_repo_matches() {
  local task_repo="$1"
  local actual_repo="$2"

  # Normalize GitHub HTTPS/SSH URLs to owner/repo.
  local normalized_actual="${actual_repo#https://github.com/}"
  normalized_actual="${normalized_actual#http://github.com/}"
  normalized_actual="${normalized_actual#git@github.com:}"
  normalized_actual="${normalized_actual#ssh://git@github.com/}"
  normalized_actual="${normalized_actual#github.com/}"
  normalized_actual="${normalized_actual%.git}"
  normalized_actual="${normalized_actual%/}"
  [ "$normalized_actual" = "$task_repo" ] && return 0

  # `git clone --local` can leave a local filesystem path as origin.
  # The workspace directory structure is $MANUL_DIR/workspace/<slug>
  # where <slug> is derived from owner/repo by replacing '/' with '-'.
  if [[ "$actual_repo" == /* ]]; then
    local resolved_path="${actual_repo%.git}"

    # Check if this is a known workspace path pattern
    if [[ "$resolved_path" == */workspace/* ]]; then
      local slug="${resolved_path##*/workspace/}"
      # Compute expected slug from task_repo (replaces '/' with '-')
      local expected_slug
      expected_slug="$(printf '%s' "$task_repo" | sed 's/\//-/g')"
      [ "$slug" = "$expected_slug" ] && return 0
    fi

    # Fallback: compare path components for arbitrary local paths
    local owner repo_name
    owner="$(basename "$(dirname "$actual_repo")")"
    repo_name="$(basename "$actual_repo")"
    repo_name="${repo_name%.git}"
    [ "${owner}/${repo_name}" = "$task_repo" ] && return 0

    local resolved_origin
    if resolved_origin="$(realpath -e "$actual_repo" 2>/dev/null)"; then
      owner="$(basename "$(dirname "$resolved_origin")")"
      repo_name="$(basename "$resolved_origin")"
      repo_name="${repo_name%.git}"
      [ "${owner}/${repo_name}" = "$task_repo" ] && return 0
    fi
  fi

  return 1
}

workspace_get_path() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local path
  path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
  if [ -z "$path" ]; then
    workspace_reclaim "$task_id" >/dev/null 2>&1 || true
    path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
  fi

  # Workspaces are pooled across repositories. Do not let a task inherit a different repo checkout.
  if [ -n "$path" ] && [ -d "$path/.git" ]; then
    local task_repo actual_repo
    task_repo="$(sqlite3 "$DB" "SELECT repository FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null)"
    if [ -n "$task_repo" ]; then
      actual_repo="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
      if [ -n "$actual_repo" ] && ! workspace_repo_matches "$task_repo" "$actual_repo"; then
        rm -rf "$path"/* "$path"/.[!.]* "$path"/..?* 2>/dev/null || true
      fi
    fi
  fi
  printf '%s\n' "$path"
}

workspace_cleanup_stale() {
  local stale_threshold="${1:-3600}"

  # Reclaim BUSY workspaces that are not owned by a live running task.
  # Queued/completed/failed tasks must never pin a workspace across daemon restarts.
  # lastUsedAt is only a coarse staleness signal for a running task.
  local has_liveness_columns
  has_liveness_columns="$(sqlite3 "$DB" "SELECT COUNT(*) FROM pragma_table_info('processed_comments') WHERE name IN ('heartbeatAt','leaseExpiresAt','workerPid');" 2>/dev/null || echo 0)"

  if [ "${has_liveness_columns:-0}" -eq 3 ]; then
    local rows
    rows="$(sqlite3 -separator '|' "$DB" "
      SELECT w.workspaceId,
             COALESCE(w.currentTaskId,''),
             COALESCE(pc.status,''),
             COALESCE(pc.heartbeatAt,''),
             COALESCE(pc.leaseExpiresAt,''),
             COALESCE(pc.workerPid,'')
      FROM workspaces w
      LEFT JOIN processed_comments pc ON pc.commentId=w.currentTaskId
      WHERE w.status='BUSY';
    " 2>/dev/null || true)"

    while IFS='|' read -r ws_id task_id task_status heartbeat_at lease_at worker_pid; do
      [ -n "$ws_id" ] || continue
      local stale=true

      if [ "$task_status" = "running" ]; then
        # A live worker owns the workspace even if its timestamps are old.
        if [ -n "$worker_pid" ] && [ "$worker_pid" != "0" ] && kill -0 "$worker_pid" 2>/dev/null; then
          stale=false
        elif [ -n "$heartbeat_at" ] && [ "$heartbeat_at" > "$(date -d "-${stale_threshold} seconds" '+%Y-%m-%d %H:%M:%S')" ] 2>/dev/null ]; then
          stale=false
        elif [ -n "$lease_at" ] && [ "$lease_at" > "$(date '+%Y-%m-%d %H:%M:%S')" ] 2>/dev/null ]; then
          stale=false
        fi
      fi

      if [ "$stale" = true ]; then
        sqlite3 "$DB" "UPDATE workspaces SET status='BROKEN' WHERE workspaceId='$(sql_escape "$ws_id")' AND status='BUSY';" 2>/dev/null || true
      fi
    done <<< "$rows"
  else
    # Backward-compatible fallback for databases predating liveness columns.
    sqlite3 "$DB" "UPDATE workspaces SET status='BROKEN' WHERE status='BUSY' AND lastUsedAt < datetime('now', '-${stale_threshold} seconds');" 2>/dev/null || true
  fi

  # Broken workspaces are disposable. Idle context-bound workspaces are
  # intentionally persistent so uncommitted PR/thread work survives between
  # comments and daemon restarts.
  sqlite3 "$DB" "
    DELETE FROM workspace_contexts
    WHERE workspaceId IN (SELECT workspaceId FROM workspaces WHERE status='BROKEN');

    DELETE FROM workspaces
    WHERE status='BROKEN'
       OR (
         lastUsedAt < datetime('now', '-${stale_threshold} seconds')
         AND status='IDLE'
         AND NOT EXISTS (
           SELECT 1 FROM workspace_contexts wc
           WHERE wc.workspaceId=workspaces.workspaceId
         )
       );
  " 2>/dev/null || true
}

workspace_available_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='IDLE'"
}

workspace_busy_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='BUSY'"
}

export -f workspace_init workspace_pool_init workspace_lease workspace_release workspace_reclaim workspace_context_acquire workspace_claim_id workspace_prepare_pr_branch workspace_mark_broken workspace_repo_matches workspace_get_path workspace_cleanup_stale workspace_available_count workspace_busy_count 2>/dev/null