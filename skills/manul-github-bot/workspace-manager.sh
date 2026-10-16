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
    # Context persistence is independent from the concurrency pool size.
    # When there is concurrency capacity but every idle workspace already
    # belongs to another context, create a fresh workspace for this new leaf.
    local busy_count max_concurrent
    busy_count="$(workspace_busy_count)"
    max_concurrent="${MAX_CONCURRENT_TASKS:-1}"
    if [ "${busy_count:-0}" -ge "${max_concurrent:-1}" ]; then
      return 1
    fi

    local new_index ws_id ws_path
    new_index="$(sqlite3 "$DB" "SELECT COALESCE(MAX(CAST(substr(workspaceId,4,instr(substr(workspaceId,4),'-')-1) AS INTEGER)), -1) + 1 FROM workspaces WHERE workspaceId LIKE 'ws-%';" 2>/dev/null || echo 0)"
    ws_id="ws-${new_index}-$(date +%s)"
    ws_path="$WORKSPACES_DIR/$ws_id"
    mkdir -p "$ws_path" || return 1
    if ! sqlite3 "$DB" "INSERT INTO workspaces(workspaceId,workspacePath,status,currentTaskId,lastUsedAt) VALUES('$(sql_escape "$ws_id")','$(sql_escape "$ws_path")','BUSY','$(sql_escape "$task_id")',datetime('now'));" 2>/dev/null; then
      rm -rf "$ws_path"
      return 1
    fi
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


# Convert a GitHub owner/repository identifier to a safe workspace-relative path.
workspace_repo_relative_path() {
  local repository="${1:-}" owner repo_name
  [[ "$repository" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] || return 1
  owner="$(printf '%s' "$repository" | cut -d/ -f1)"
  repo_name="$(printf '%s' "$repository" | cut -d/ -f2)"
  [ "$owner" != "." ] && [ "$owner" != ".." ] || return 1
  [ "$repo_name" != "." ] && [ "$repo_name" != ".." ] || return 1
  printf 'repos/%s/%s\n' "$owner" "$repo_name"
}

# Resolve a nested checkout path strictly inside the leased workspace root.
# Symlinked path components are rejected to prevent path traversal.
workspace_primary_repo_path() {
  local workspace_root="$1" repository="$2"
  local relative root_real owner repo_name repos_path owner_path checkout_path resolved
  relative="$(workspace_repo_relative_path "$repository")" || return 1
  root_real="$(realpath -e "$workspace_root" 2>/dev/null)" || return 1
  [ -d "$root_real" ] || return 1
  repos_path="$root_real/repos"
  [ ! -L "$repos_path" ] || return 1
  mkdir -p "$repos_path" || return 1
  [ "$(realpath -e "$repos_path" 2>/dev/null)" = "$root_real/repos" ] || return 1
  owner="$(printf '%s' "$relative" | cut -d/ -f2)"
  repo_name="$(basename "$relative")"
  owner_path="$repos_path/$owner"
  [ ! -L "$owner_path" ] || return 1
  mkdir -p "$owner_path" || return 1
  [ "$(realpath -e "$owner_path" 2>/dev/null)" = "$repos_path/$owner" ] || return 1
  checkout_path="$owner_path/$repo_name"
  [ ! -L "$checkout_path" ] || return 1
  resolved="$(realpath -m "$checkout_path" 2>/dev/null)" || return 1
  case "$resolved" in "$root_real"/*) ;; *) return 1 ;; esac
  [ "$resolved" = "$checkout_path" ] || return 1
  printf '%s\n' "$checkout_path"
}

# Move an existing legacy root checkout as one unit. This preserves .git,
# ignored files, local commits, and dirty PR work across the layout migration.
workspace_migrate_legacy_checkout() {
  local workspace_root="$1" repository="$2"
  local relative root_real actual_root actual_origin workspace_parent workspace_name staging owner repo_name
  root_real="$(realpath -e "$workspace_root" 2>/dev/null)" || return 1
  [ -e "$root_real/.git" ] || return 0
  [ ! -L "$root_real/.git" ] || return 1
  actual_root="$(git -C "$root_real" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$actual_root" ] && [ "$(realpath -e "$actual_root" 2>/dev/null)" = "$root_real" ] || return 1
  actual_origin="$(git -C "$root_real" remote get-url origin 2>/dev/null || true)"
  workspace_repo_matches "$repository" "$actual_origin" || return 2
  relative="$(workspace_repo_relative_path "$repository")" || return 1
  owner="$(printf '%s' "$relative" | cut -d/ -f2)"
  repo_name="$(basename "$relative")"
  workspace_parent="$(dirname "$root_real")"
  workspace_name="$(basename "$root_real")"
  staging="$workspace_parent/.${workspace_name}.migration.$$"
  [ ! -e "$staging" ] || return 1
  mv "$root_real" "$staging" || return 1
  if ! mkdir -p "$root_real/repos/$owner"; then
    rmdir "$root_real" 2>/dev/null || true
    mv "$staging" "$root_real" 2>/dev/null || true
    return 1
  fi
  if ! mv "$staging" "$root_real/repos/$owner/$repo_name"; then
    rmdir "$root_real/repos/$owner" "$root_real/repos" "$root_real" 2>/dev/null || true
    mv "$staging" "$root_real" 2>/dev/null || true
    return 1
  fi
  return 0
}

# Prepare the primary checkout inside the task root. Never erase an existing
# mismatched checkout because it may hold unpushed commits or user changes.
workspace_prepare_primary_checkout() {
  local workspace_root="$1" repository="$2" repo_cache="$3"
  local checkout actual_origin
  workspace_migrate_legacy_checkout "$workspace_root" "$repository" || return $?
  checkout="$(workspace_primary_repo_path "$workspace_root" "$repository")" || return 1
  if [ -e "$checkout" ]; then
    if [ ! -e "$checkout/.git" ] || [ -L "$checkout/.git" ]; then
      return 2
    fi
    actual_origin="$(git -C "$checkout" remote get-url origin 2>/dev/null || true)"
    workspace_repo_matches "$repository" "$actual_origin" || return 2
  else
    [ -d "$repo_cache/.git" ] || return 1
    if ! git clone --local --no-hardlinks "$repo_cache" "$checkout" 2>/dev/null; then
      [ ! -e "$checkout" ] || rm -rf -- "$checkout"
      return 1
    fi
    git -C "$checkout" remote set-url origin "https://github.com/$repository" || return 1
  fi
  mkdir -p "$(realpath -e "$workspace_root")/tmp" || return 1
  printf '%s\n' "$checkout"
}

# Clone configured related repositories into this task's workspace. The shared
# cache is a source only. Related repos are read-only by default; dirty/diverged
# prior checkouts are preserved and reported instead of destructively reset.
workspace_prepare_related_checkouts() {
  local workspace_root="$1" primary_repository="$2"
  shift 2
  WORKSPACE_RELATED_PATHS=""
  WORKSPACE_RELATED_UNAVAILABLE=""
  local repository cache cache_rc checkout relative actual_origin branch local_head cache_head
  for repository in "$@"; do
    [ -n "$repository" ] || continue
    if [ "$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$primary_repository" | tr '[:upper:]' '[:lower:]')" ]; then
      continue
    fi
    relative="$(workspace_repo_relative_path "$repository" 2>/dev/null || true)"
    if [ -z "$relative" ]; then
      [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
      WORKSPACE_RELATED_UNAVAILABLE+="- $repository: invalid repository identifier"
      continue
    fi
    checkout="$(workspace_primary_repo_path "$workspace_root" "$repository" 2>/dev/null || true)"
    if [ -z "$checkout" ]; then
      [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
      WORKSPACE_RELATED_UNAVAILABLE+="- $repository: unsafe checkout path"
      continue
    fi
    cache_rc=0
    cache="$(ensure_repo "$repository")" || cache_rc=$?
    if [ "$cache_rc" -ne 0 ] || [ -z "$cache" ] || [ ! -d "$cache/.git" ]; then
      [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
      WORKSPACE_RELATED_UNAVAILABLE+="- $repository: shared cache unavailable (status $cache_rc)"
      continue
    fi

    if [ ! -e "$checkout" ]; then
      if git clone --local --no-hardlinks "$cache" "$checkout" >/dev/null 2>&1; then
        if ! git -C "$checkout" remote set-url origin "https://github.com/$repository" >/dev/null 2>&1; then
          rm -rf -- "$checkout"
          [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
          WORKSPACE_RELATED_UNAVAILABLE+="- $repository: failed to configure origin"
          release_repo_lock "$repository"
          continue
        fi
      else
        [ ! -e "$checkout" ] || rm -rf -- "$checkout"
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: clone failed"
        release_repo_lock "$repository"
        continue
      fi
    else
      if [ ! -e "$checkout/.git" ] || [ -L "$checkout/.git" ]; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: existing checkout is not a Git repository; preserved"
        release_repo_lock "$repository"
        continue
      fi
      actual_origin="$(git -C "$checkout" remote get-url origin 2>/dev/null || true)"
      if ! workspace_repo_matches "$repository" "$actual_origin"; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: existing checkout origin mismatch; preserved"
        release_repo_lock "$repository"
        continue
      fi
      if ! git -C "$checkout" diff --quiet 2>/dev/null || ! git -C "$checkout" diff --cached --quiet 2>/dev/null; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: existing checkout has tracked changes; preserved"
        release_repo_lock "$repository"
        continue
      fi
      branch="$(git -C "$cache" symbolic-ref --short HEAD 2>/dev/null || git -C "$cache" branch --show-current 2>/dev/null || true)"
      if [ -z "$branch" ] || [ "$(git -C "$checkout" symbolic-ref --short HEAD 2>/dev/null || true)" != "$branch" ]; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: existing checkout is on a different/detached branch; preserved"
        release_repo_lock "$repository"
        continue
      fi
      if ! git -C "$checkout" fetch --quiet "$cache" "+refs/heads/$branch:refs/remotes/manul-cache/$branch" 2>/dev/null; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: could not refresh from the current cache"
        release_repo_lock "$repository"
        continue
      fi
      local_head="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)"
      cache_head="$(git -C "$checkout" rev-parse "refs/remotes/manul-cache/$branch" 2>/dev/null || true)"
      if [ -z "$cache_head" ]; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: refreshed branch ref is missing"
        release_repo_lock "$repository"
        continue
      elif [ "$local_head" != "$cache_head" ]; then
        if git -C "$checkout" merge-base --is-ancestor "$local_head" "$cache_head" 2>/dev/null; then
          if ! git -C "$checkout" merge --ff-only "$cache_head" >/dev/null 2>&1; then
            [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
            WORKSPACE_RELATED_UNAVAILABLE+="- $repository: fast-forward refresh failed; preserved"
            release_repo_lock "$repository"
            continue
          fi
        else
          [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
          WORKSPACE_RELATED_UNAVAILABLE+="- $repository: local commits would be overwritten by refresh; preserved"
          release_repo_lock "$repository"
          continue
        fi
      fi
    fi
    release_repo_lock "$repository"
    [ -z "$WORKSPACE_RELATED_PATHS" ] || WORKSPACE_RELATED_PATHS+=$'\n'
    WORKSPACE_RELATED_PATHS+="- $repository: $relative (read-only)"
  done
  return 0
}

workspace_get_path() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local expected_ws_id="${2:-}"
  local safe_ws_id=""
  local mapped_ws_id=""
  local path

  # Prefer an explicit lease ID from dispatch. For helper callers that do not
  # pass one, follow the task's persisted mapping before using the legacy
  # currentTaskId lookup used by context-only test fixtures.
  if [ -z "$expected_ws_id" ]; then
    expected_ws_id="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null || true)"
  fi
  if [ -n "$expected_ws_id" ]; then
    safe_ws_id="$(sql_escape "$expected_ws_id")"
    path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
  else
    path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
  fi

  if [ -z "$path" ]; then
    mapped_ws_id="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null || true)"
    # Reclaim only if the task's persisted mapping agrees with the explicit
    # lease, otherwise fail closed instead of reclaiming another workspace.
    if [ -z "$expected_ws_id" ] || [ "$mapped_ws_id" = "$expected_ws_id" ]; then
      workspace_reclaim "$task_id" >/dev/null 2>&1 || true
      if [ -n "$expected_ws_id" ]; then
        path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
      else
        path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
      fi
    fi
  fi

  # Resolve and validate the workspace root before probing any checkout.
  # A DB value or symlink must never make this helper inspect another workspace.
  if [ -n "$path" ]; then
    local root_real expected_path expected_real registered_real
    if [ -z "$expected_ws_id" ]; then
      expected_ws_id="$(sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null || true)"
    fi
    root_real="$(realpath -e "$WORKSPACES_DIR" 2>/dev/null || true)"
    expected_path="$WORKSPACES_DIR/$expected_ws_id"
    expected_real="$(realpath -e "$expected_path" 2>/dev/null || true)"
    registered_real="$(realpath -e "$path" 2>/dev/null || true)"
    if [ -z "$root_real" ] || [ -z "$expected_ws_id" ] || [ -L "$expected_path" ] || [ -L "$path" ] || [ -z "$expected_real" ] || [ "$expected_real" != "$root_real/$expected_ws_id" ] || [ "$registered_real" != "$expected_real" ]; then
      path=""
    fi
  fi
  [ -n "$path" ] || { printf '\n'; return 0; }

  # Validate root and nested primary checkouts. Preserve mismatched checkout
  # state because it may contain unpushed PR commits or uncommitted changes.
  if [ -n "$path" ]; then
    local task_repo actual_repo candidate_checkout relative
    task_repo="$(sqlite3 "$DB" "SELECT repository FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null)"
    candidate_checkout="$path"
    if [ -n "$task_repo" ] && [ ! -e "$path/.git" ]; then
      relative="$(workspace_repo_relative_path "$task_repo" 2>/dev/null || true)"
      if [ -z "$relative" ]; then
        path=""
      else
        local owner_component
        owner_component="$(printf '%s' "$relative" | cut -d/ -f2)"
        if [ -L "$path/repos" ] || [ -L "$path/repos/$owner_component" ] || [ -L "$path/$relative" ]; then
          path=""
        else
          candidate_checkout="$path/$relative"
        fi
      fi
    fi
    if [ -n "$path" ] && [ -e "$candidate_checkout/.git" ] && [ -n "$task_repo" ]; then
      actual_repo="$(git -C "$candidate_checkout" remote get-url origin 2>/dev/null || true)"
      if [ -n "$actual_repo" ] && ! workspace_repo_matches "$task_repo" "$actual_repo"; then
        path=""
      fi
    fi
  fi
  printf '%s\n' "$path"
}

# Validate both lease ownership and the exact physical checkout path before
# dispatch. A valid BUSY row is not enough if the executor is pointed at a
# different workspace (for example, a stale checkout from an earlier task).
workspace_owned_path_matches() {
  local ws_id="$1"
  local task_id="$2"
  local candidate_path="$3"
  [ -n "$ws_id" ] && [ -n "$task_id" ] && [ -n "$candidate_path" ] || return 1

  local safe_ws_id safe_task_id registered_path workspace_root registered_real candidate_real
  safe_ws_id="$(sql_escape "$ws_id")"
  safe_task_id="$(sql_escape "$task_id")"
  registered_path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null || true)"
  [ -n "$registered_path" ] && [ -d "$registered_path" ] && [ -d "$candidate_path" ] || return 1

  workspace_root="$(realpath -e "$WORKSPACES_DIR" 2>/dev/null)" || return 1
  registered_real="$(realpath -e "$registered_path" 2>/dev/null)" || return 1
  candidate_real="$(realpath -e "$candidate_path" 2>/dev/null)" || return 1

  case "$registered_real" in
    "$workspace_root"/*) ;;
    *) return 1 ;;
  esac
  [ "$registered_real" = "$candidate_real" ]
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

export -f workspace_init workspace_pool_init workspace_lease workspace_release workspace_reclaim workspace_context_acquire workspace_claim_id workspace_prepare_pr_branch workspace_mark_broken workspace_repo_matches workspace_repo_relative_path workspace_primary_repo_path workspace_migrate_legacy_checkout workspace_prepare_primary_checkout workspace_prepare_related_checkouts workspace_get_path workspace_owned_path_matches workspace_cleanup_stale workspace_available_count workspace_busy_count 2>/dev/null