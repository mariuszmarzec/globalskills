#!/usr/bin/bash
# manul-daemon.sh — background poll loop for the manul GitHub bot.
#
# Usage:
#   manul-daemon.sh start      — start the poll loop (setsid, survives gateway restarts)
#   manul-daemon.sh stop       — stop it
#   manul-daemon.sh status     — is it running?
#   manul-daemon.sh run-once   — single poll + dispatch (for testing)
#
# Loop: every $MANUL_INTERVAL (default from config pollInterval, else 60s) run
# poll.sh; when it reports fire:true, claim one queued task atomically in SQLite,
# post an in-progress comment, invoke the implementation agent with a per-task
# prompt, validate the result via explicit markers, update SQLite, and post the
# final result comment.
set -uo pipefail

# Ensure standard PATH is available when running via setsid/nohup
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# Ensure OpenClaw uses the native state directory (post-migration)
export OPENCLAW_STATE_DIR="/home/marzec/.openclaw-native/state"
export OPENCLAW_CONFIG_PATH="/home/marzec/.openclaw-native/openclaw.json"

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="${MANUL_DIR}/config.json"
POLL="$MANUL_DIR/poll.sh"
PROMPT_FILE="$MANUL_DIR/orchestrator.prompt.md"
PID_FILE="$MANUL_DIR/daemon.pid"
LOG="$MANUL_DIR/daemon.log"
LOCK="$MANUL_DIR/lock"
DB="$MANUL_DIR/manul.db"
CFG_INTERVAL="$(jq -r '.pollInterval // empty' "$CONFIG" 2>/dev/null)"
INTERVAL="${MANUL_INTERVAL:-${CFG_INTERVAL:-60}}"
AGENT_TIMEOUT="${MANUL_AGENT_TIMEOUT:-1800}"   # seconds for the agent turn
OPENCLAW_BIN="$(command -v openclaw)"

# Read heartbeat configuration from config.json
CFG_HEARTBEAT_INTERVAL="$(jq -r '.automation.heartbeatInterval // 60' "$CONFIG" 2>/dev/null)"
HEARTBEAT_INTERVAL="${MANUL_HEARTBEAT_INTERVAL:-${CFG_HEARTBEAT_INTERVAL:-60}}"
CFG_HEARTBEAT_TIMEOUT="$(jq -r '.automation.heartbeatTimeout // 900' "$CONFIG" 2>/dev/null)"
HEARTBEAT_TIMEOUT="${MANUL_HEARTBEAT_TIMEOUT:-${CFG_HEARTBEAT_TIMEOUT:-900}}"
CFG_LEASE_TIMEOUT="$(jq -r '.automation.leaseTimeout // 900' "$CONFIG" 2>/dev/null)"
LEASE_TIMEOUT="${MANUL_LEASE_TIMEOUT:-${CFG_LEASE_TIMEOUT:-900}}"

log() { echo "[$(date -Is)] $*" >>"$LOG"; }

# Get daemon PID as a function (handles empty file safely)
get_daemon_pid() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
    echo "$pid"
  else
    echo "0"
  fi
}

# Repository management functions for manul-daemon.sh

# Ensure target repository exists in Manul workspace
ensure_repo() {
  local repo="$1"
  local repo_slug
  repo_slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  local repo_dir="/mnt/f/ubuntu-workspace/.openclaw/manul/workspace/$repo_slug"
  local lockfile="/mnt/f/ubuntu-workspace/.openclaw/manul/repo-locks/${repo_slug}.lock"

  # Check if repo already exists and is up-to-date
  if [ -d "$repo_dir" ] && [ -d "$repo_dir/.git" ]; then
    # Verify this is the correct repository
    local actual_repo
    actual_repo="$(cd "$repo_dir" && git remote get-url origin)"
    if [[ "$actual_repo" == "https://github.com/${repo}" ]]; then
      # Synchronize with remote
      cd "$repo_dir" && git fetch origin --quiet
      local head
      local remote_head
      head=$(git rev-parse HEAD)
      remote_head=$(git rev-parse "origin/$(git symbolic-ref --short HEAD 2>/dev/null || git branch --show-current)" 2>/dev/null || git rev-parse "origin/master" 2>/dev/null)
      if [ "$head" != "$remote_head" ]; then
        log "repo $repo needs update, pulling"
        cd "$repo_dir" && git reset --hard "origin/$(git symbolic-ref --short HEAD 2>/dev/null || git branch --show-current)" --quiet 2>/dev/null || git reset --hard origin/master --quiet 2>/dev/null
      fi
      log "repo $repo is ready at $repo_dir"
      echo "$repo_dir"
      return 0
    else
      log "repo $repo origin mismatch, expected https://github.com/${repo}, got $actual_repo"
      rm -rf "$repo_dir"
    fi
  fi

  # Acquire repo lock to prevent concurrent access
  if ! acquire_repo_lock "$repo"; then
    log "repo $repo is locked or stale, skipping"
    return 1
  fi

  # Clone fresh repository
  log "cloning repo $repo to $repo_dir"
  rm -rf "$repo_dir"
  mkdir -p "$repo_dir"
  cd "$repo_dir"

  # Clone with minimal fetch
  if ! git clone --depth 1 "https://github.com/${repo}" . 2>/dev/null; then
    log "FAILED to clone repo $repo"
    rm -rf "$repo_dir"
    release_repo_lock "$repo"
    return 1
  fi

  log "repo $repo cloned successfully to $repo_dir"
  echo "$repo_dir"
  return 0
}

# Verify repository ownership and integrity
verify_repo() {
  local repo="$1"
  local repo_dir="$2"

  if [ -z "$repo_dir" ] || [ ! -d "$repo_dir" ] || [ ! -d "$repo_dir/.git" ]; then
    log "ERROR: repo_dir $repo_dir is not a valid git repository"
    return 1
  fi

  # Verify this is the correct repository
  local actual_repo
  actual_repo="$(cd "$repo_dir" && git remote get-url origin 2>/dev/null)"
  local expected_repo="https://github.com/${repo}"

  if [ "$actual_repo" != "$expected_repo" ]; then
    log "ERROR: repo_dir $repo_dir has wrong origin: $actual_repo, expected $expected_repo"
    return 1
  fi

  # Verify we're not in OpenClaw's default workspace
  if [[ "$repo_dir" == "/home/marzec/.openclaw-native/state/workspace/"* ]]; then
    log "ERROR: repo_dir $repo_dir appears to be OpenClaw's default workspace, not task repository"
    return 1
  fi

  log "repo $repo verified at $repo_dir"
  return 0
}

# Acquire repository lock (same function as in poll.sh)
acquire_repo_lock() {
  local repo="$1"
  local slug
  slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  local lockfile="${REPO_LOCK_DIR:-/mnt/f/ubuntu-workspace/.openclaw/manul/repo-locks}/${slug}.lock"

  if [ -f "$lockfile" ]; then
    local age
    age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$REPO_LOCK_TTL" ]; then
      log "repo $repo is locked by another task (age=${age}s, ttl=${REPO_LOCK_TTL}s); skipping"
      return 1
    fi

    # Lock is stale — but only remove it if no task is currently running for
    # this repo in DB.
    local running_count
    local safe_repo
    safe_repo="$(sql_escape "$repo")"
    running_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE repository='$safe_repo' AND status='running';" 2>/dev/null || echo 0)"

    if [ "${running_count:-0}" -gt 0 ]; then
      log "stale repo lock for $repo ignored because task is still running in DB (running=$running_count); skipping"
      return 1
    fi

    log "stale repo lock for $repo removed (age=${age}s, no running tasks)"
    rm -f "$lockfile"
  fi

  date +%s >"$lockfile"
  return 0
}

release_repo_lock() {
  local repo="$1"
  local slug
  slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  rm -f "${REPO_LOCK_DIR:-/mnt/f/ubuntu-workspace/.openclaw/manul/repo-locks}/${slug}.lock"
}

# Enhanced SQLite UPDATE with verification and error handling
update_task_completion() {
  local comment_id="$1"
  local safe_comment_id="$(sql_escape "$comment_id")"
  local status="$2"
  local error_message="${3:-}"

  # Verify task exists before updating
  local task_exists
  task_exists="$(sqlite3 "$DB" "SELECT 1 FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
  if [ -z "$task_exists" ]; then
    log "ERROR: Task $comment_id does not exist in database"
    return 1
  fi

  # Verify task is in a state that can transition to the target status
  local current_status
  current_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  # Validate state transitions
  case "$status" in
    "completed")
      if [ "$current_status" != "running" ]; then
        log "ERROR: Cannot complete task $comment_id from current status: $current_status"
        return 1
      fi
      ;;
    "failed")
      if [ "$current_status" != "running" ] && [ "$current_status" != "queued" ]; then
        log "ERROR: Cannot fail task $comment_id from current status: $current_status"
        return 1
      fi
      ;;
    "queued")
      if [ "$current_status" != "running" ]; then
        log "ERROR: Cannot requeue task $comment_id from current status: $current_status"
        return 1
      fi
      ;;
  esac

  # Perform the update with worker ownership verification for completion/failure
  local where_clause="WHERE commentId='$safe_comment_id'"

  # For completed/failed tasks, verify worker ownership to prevent stealing
  if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
    local current_daemon_pid
    current_daemon_pid="$(get_daemon_pid)"
    where_clause="WHERE commentId='$safe_comment_id' AND workerPid=$current_daemon_pid"

    # If no workerPid assigned yet, this is a transition from queued
    if [ "$current_status" = "queued" ]; then
      where_clause="WHERE commentId='$safe_comment_id'"
    fi
  fi

  # Execute the update
  local update_sql="UPDATE processed_comments SET status='$status'"

  case "$status" in
    "completed")
      update_sql+=" , processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL"
      ;;
    "failed")
      update_sql+=" , processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL"
      ;;
    "queued")
      update_sql+=" , processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL"
      ;;
  esac

  update_sql+=" $where_clause;"

  # Execute the update and capture changes() in the same connection
  local update_result
  update_result="$(sqlite3 "$DB" "$update_sql; SELECT changes();" 2>/dev/null)"
  local changes
  changes="$(echo "$update_result" | tail -n 1)"

  if [ "${changes:-0}" -eq 1 ]; then
    log "SUCCESS: Task $comment_id transitioned to $status (previous: $current_status)"
    return 0
  else
    log "ERROR: Task $comment_id update failed (changes=$changes, previous: $current_status)"
    return 1
  fi
}

# Finalization verification: ensure heartbeat and locks don't revert completion
verify_finalization() {
  local comment_id="$1"
  local safe_comment_id="$(sql_escape "$comment_id")"

  # Verify task is completed in SQLite
  local task_status
  task_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ "$task_status" != "completed" ]; then
    log "ERROR: Task $comment_id is not completed in SQLite (status: $task_status)"
    return 1
  fi

  # Verify processedAt is set
  local processed_at
  processed_at="$(sqlite3 "$DB" "SELECT processedAt FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ -z "$processed_at" ] || [ "$processed_at" = "null" ]; then
    log "ERROR: Task $comment_id has no processedAt timestamp"
    return 1
  fi

  # Verify heartbeat is stopped (no running heartbeat)
  local heartbeat_pid
  heartbeat_pid="$(cat "$MANUL_DIR/task-${comment_id}.heartbeat.pid" 2>/dev/null)"

  if [ -n "$heartbeat_pid" ] && kill -0 "$heartbeat_pid" 2>/dev/null; then
    log "ERROR: Task $comment_id still has a running heartbeat (pid: $heartbeat_pid)"
    return 1
  fi

  # Verify workerPid is cleared
  local worker_pid
  worker_pid="$(sqlite3 "$DB" "SELECT workerPid FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ -n "$worker_pid" ] && [ "$worker_pid" != "0" ]; then
    log "ERROR: Task $comment_id still has workerPid: $worker_pid"
    return 1
  fi

  log "SUCCESS: Task $comment_id finalization verified"
  return 0
}

# Enhanced task completion with verification
complete_task_with_verification() {
  local comment_id="$1"
  local safe_comment_id="$(sql_escape "$comment_id")"

  # Mark task as completed with verification
  if ! update_task_completion "$comment_id" "completed"; then
    log "ERROR: Failed to complete task $comment_id"
    return 1
  fi

  # Verify finalization
  if ! verify_finalization "$comment_id"; then
    log "ERROR: Finalization verification failed for task $comment_id"
    # Attempt to fix
    update_task_completion "$comment_id" "queued"
    return 1
  fi

  log "SUCCESS: Task $comment_id fully completed and verified"
  return 0
}

# Acquire singleton lock BEFORE claiming a task to prevent concurrent daemon races
acquire_task_lock() {
  local lock_dir="$MANUL_DIR/.daemon-lock"
  local max_wait=30  # seconds
  local elapsed=0

  while ! mkdir "$lock_dir" 2>/dev/null; do
    # Check if lock holder is still alive
    if [ -f "$PID_FILE" ]; then
      local lock_pid
      lock_pid="$(cat "$PID_FILE" 2>/dev/null)"
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        # Stale lock — remove and retry
        rm -rf "$lock_dir" 2>/dev/null
        continue
      fi
    else
      rm -rf "$lock_dir" 2>/dev/null
      continue
    fi
    sleep 0.1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$max_wait" ]; then
      log "WARN: could not acquire task lock after ${max_wait}s"
      return 1
    fi
  done
  return 0
}

release_task_lock() {
  rmdir "$MANUL_DIR/.daemon-lock" 2>/dev/null || true
}

# Heartbeat tracking for long-running tasks
declare -A HEARTBEAT_PIDS

start_heartbeat() {
  local comment_id="$1"
  local pid=$$
  HEARTBEAT_PIDS["$comment_id"]=$pid
  log "started heartbeat for task $comment_id (pid $pid)"
}

stop_heartbeat() {
  local comment_id="$1"
  unset HEARTBEAT_PIDS["$comment_id"]
  log "stopped heartbeat for task $comment_id (pid ${HEARTBEAT_PIDS[$comment_id]:-unknown})"
}

start() {
  # Singleton check: verify no other daemon is running
  if [ -f "$PID_FILE" ]; then
    local existing_pid
    existing_pid="$(cat "$PID_FILE" 2>/dev/null)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "already running (pid $existing_pid)"
      return 0
    fi
    # Stale PID file — remove it
    rm -f "$PID_FILE"
  fi

  setsid nohup "$0" loop >>"$LOG" 2>&1 &
  echo $! >"$PID_FILE"
  echo "manul daemon started (pid $(cat "$PID_FILE"), interval ${INTERVAL}s)"
}

stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "not running"
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null
  rm -f "$PID_FILE"
  echo "manul daemon stopped (pid $pid)"
}

status() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "running (pid $(cat "$PID_FILE"))"
  else
    echo "not running"
  fi
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

post_github_comment() {
  local repo="$1"
  local issue="$2"
  local body="$3"

  # Append Manul signature to automated comments (deterministic)
  local signed_body="$body — manul 🐈"

  gh issue comment "$issue" --repo "$repo" --body "$signed_body" 2>>"$LOG"
}

run_once() {
  local out
  out="$("$POLL")"
  echo "$out"
  if printf '%s' "$out" | grep -q '"fire":true'; then
    log "dispatch: $out"

    # 0. Acquire singleton lock BEFORE any claim to prevent concurrent daemon races
    if ! acquire_task_lock; then
      log "dispatch: could not acquire lock, skipping"
      return 0
    fi

    # 1. Find oldest queued task using proper SQLite query
    # Query only the fields we need, not the prompt (which may contain |)
    local TASK_INFO
    TASK_INFO="$(sqlite3 "$DB" "SELECT commentId, repository, issueNumber, attempts FROM processed_comments WHERE status='queued' ORDER BY createdAt ASC LIMIT 1;" 2>/dev/null)"

    if [ -z "$TASK_INFO" ]; then
      log "dispatch: fire:true but no queued task found"
      release_task_lock
      return 0
    fi

    # Safe parsing: only three simple fields separated by |
    local COMMENT_ID REPO ISSUE_NUM ATTEMPTS
    IFS='|' read -r COMMENT_ID REPO ISSUE_NUM ATTEMPTS <<< "$TASK_INFO"
    [ -n "$COMMENT_ID" ] || { release_task_lock; return 0; }

    # Escape for SQL
    local safe_comment_id
    safe_comment_id="$(sql_escape "$COMMENT_ID")"
    local safe_repo
    safe_repo="$(sql_escape "$REPO")"

    # Read actual attempts from database (authoritative source)
    local ACTUAL_ATTEMPTS
    ACTUAL_ATTEMPTS="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$safe_comment_id' AND status='queued';" 2>/dev/null || echo "0")"

    # Check max attempts BEFORE claiming (guard against watchdog recovery resetting attempts)
    local MAX_ATTEMPTS
    MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // 3' "$CONFIG" 2>/dev/null || echo 3)"
    if [ "${ACTUAL_ATTEMPTS:-0}" -ge "$MAX_ATTEMPTS" ]; then
      log "dispatch: task $COMMENT_ID already at max attempts ($ACTUAL_ATTEMPTS >= $MAX_ATTEMPTS), marking as failed"
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$safe_comment_id';" 2>/dev/null
      local FINAL_COMMENT="❌ Manul failed to complete the task after $ACTUAL_ATTEMPTS attempts (max reached)."
      post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" || log "WARN: failed to post final comment for $COMMENT_ID"
      release_task_lock
      return 0
    fi

    # 2. Atomically claim the task (queued -> running, attempts+1)
    # Include workerPid check to prevent stealing from another worker
    local CURRENT_DAEMON_PID
    CURRENT_DAEMON_PID="$(get_daemon_pid)"
    local CLAIM_RESULT
    CLAIM_RESULT="$(sqlite3 "$DB" "UPDATE processed_comments SET status='running', attempts=attempts+1, processedAt=datetime('now'), heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now', '+${LEASE_TIMEOUT} seconds'), workerPid=$CURRENT_DAEMON_PID WHERE commentId='$safe_comment_id' AND status='queued' AND (workerPid IS NULL OR workerPid=0 OR NOT EXISTS (SELECT 1 FROM processed_comments pc2 WHERE pc2.commentId='$safe_comment_id' AND pc2.workerPid=$CURRENT_DAEMON_PID AND pc2.status='running' AND pc2.workerPid != $CURRENT_DAEMON_PID)); SELECT changes();" 2>/dev/null)"

    local CHANGED
    CHANGED="$(echo "$CLAIM_RESULT" | tail -n 1)"

    if [ "${CHANGED:-0}" -ne 1 ]; then
      log "dispatch: task $COMMENT_ID not claimed (changed=$CHANGED)"
      release_task_lock
      return 0
    fi

    # 3. Read task details after claiming — query each field separately
    # to avoid pipe-delimited parsing issues with prompt containing |
    local COMMENT_URL AUTHOR AGENT TASK_PROMPT TASK_CONTEXT
    COMMENT_URL="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    AUTHOR="$(sqlite3 "$DB" "SELECT author FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    AGENT="$(sqlite3 "$DB" "SELECT agent FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_PROMPT="$(sqlite3 "$DB" "SELECT prompt FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_CONTEXT="$(sqlite3 "$DB" "SELECT context FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

    log "dispatch: claimed task $COMMENT_ID ($REPO#$ISSUE_NUM), attempts now $((ACTUAL_ATTEMPTS + 1))"

    # Start heartbeat for long-running task
    start_heartbeat "$COMMENT_ID"

    # 4. Post "in progress" comment BEFORE invoking the LLM
    local IN_PROGRESS_BODY="🔄 Manul is working on this task..."

    if ! post_github_comment "$REPO" "$ISSUE_NUM" "$IN_PROGRESS_BODY"; then
      log "dispatch: FAILED to post in-progress comment for $COMMENT_ID, reverting to queued"
      stop_heartbeat "$COMMENT_ID"
      sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL WHERE commentId='$safe_comment_id';" 2>/dev/null
      release_task_lock
      return 0
    fi

    log "dispatch: posted in-progress comment for $COMMENT_ID"

    # 5. Create per-task prompt containing the actual task payload
    local TASK_PROMPT_DIR="$MANUL_DIR/tasks"
    mkdir -p "$TASK_PROMPT_DIR"
    local TASK_PROMPT_FILE="$TASK_PROMPT_DIR/task-${COMMENT_ID}.md"

    # Determine task type from commentUrl metadata (do NOT call gh pr view)
    local TASK_TYPE="issue"
    if [[ "$COMMENT_URL" == *"/pull/"* ]]; then
      if [[ "$COMMENT_URL" == *"#discussion_r"* ]]; then
        TASK_TYPE="pr_review_comment"
      else
        TASK_TYPE="pr_conversation_comment"
      fi
    fi

    cat > "$TASK_PROMPT_FILE" <<PROMPT_EOF
# Manul Task:

You are the Manul implementation agent. Complete ONE task and then emit exactly one of the completion markers.

## Task
- Repository: $REPO
- Issue/PR: #$ISSUE_NUM
- Comment ID: $COMMENT_ID
- Comment URL: $COMMENT_URL
- Task Type: $TASK_TYPE

## User Request
$TASK_PROMPT

## Context
$TASK_CONTEXT

## Rules
1. Inspect the local repository and implement the requested change.
2. Run appropriate tests/validation.
3. Make the requested code changes.
4. When finished, output exactly: \`TASK_DONE\`
5. If you cannot complete the task, output exactly: \`TASK_FAILED: <brief reason>\`
6. Do NOT modify \`manul.db\`.
7. Do NOT manage Manul task state.
8. Do NOT post GitHub comments or PR reviews.
PROMPT_EOF

    # Repository Management: Ensure target repository exists and is authoritative
    local REPO_DIR
    REPO_DIR="$(ensure_repo "$REPO")"
    if [ $? -ne 0 ]; then
      log "dispatch: FAILED to ensure repository $REPO, failing task"
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$safe_comment_id';" 2>/dev/null
      local FINAL_COMMENT="❌ Manul failed to access the repository $REPO."
      post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" || log "WARN: failed to post final comment for $COMMENT_ID"
      stop_heartbeat "$COMMENT_ID"
      release_task_lock
      return 0
    fi

    # Verify repository integrity
    if ! verify_repo "$REPO" "$REPO_DIR"; then
      log "dispatch: REPOSITORY VERIFICATION FAILED for $REPO, failing task"
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$safe_comment_id';" 2>/dev/null
      local FINAL_COMMENT="❌ Manul repository verification failed for $REPO."
      post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" || log "WARN: failed to post final comment for $COMMENT_ID"
      stop_heartbeat "$COMMENT_ID"
      release_repo_lock "$REPO"
      release_task_lock
      return 0
    fi

    # 6. Set task-specific working directory inside repository
    local TASK_WORKDIR
    TASK_WORKDIR="$REPO_DIR/task-$COMMENT_ID"
    mkdir -p "$TASK_WORKDIR"

    log "dispatch: task $COMMENT_ID repository located at $REPO_DIR, working dir: $TASK_WORKDIR"

    # Update prompt to include authoritative repository path
    cat >> "$TASK_PROMPT_FILE" <<PROMPT_APPEND

## Authoritative Repository
The target repository for this task is located at: $REPO_DIR

## Working Directory
You will execute in the following task workspace (inside the repository):
$TASK_WORKDIR

Please navigate to this directory and implement the requested changes. The repository at $REPO_DIR is the authoritative source for this task.
PROMPT_APPEND

    # 6. Invoke implementation agent with the per-task prompt, ensuring proper working directory
    local STDOUT_FILE="$MANUL_DIR/tasks/task-${COMMENT_ID}.stdout"
    local STDERR_FILE="$MANUL_DIR/tasks/task-${COMMENT_ID}.stderr"

    log "dispatch: invoking agent manul for task $COMMENT_ID"

    # Change to repository directory and invoke agent
    local prev_dir
    prev_dir="$(pwd)"
    cd "$TASK_WORKDIR" || { log "ERROR: cannot enter task workspace $TASK_WORKDIR, failing task"; return 0; }
    timeout -k 60 "$AGENT_TIMEOUT" "$OPENCLAW_BIN" agent --agent main --message-file "$TASK_PROMPT_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE"
    local rc=$?
    cd "$prev_dir" 2>/dev/null || log "WARN: failed to restore working directory"

    log "dispatch: agent finished rc=$rc for task $COMMENT_ID"

    # 7. Determine success using BOTH exit status AND explicit completion marker
    local SUCCESS="false"
    local FAIL_REASON=""

    if [ $rc -eq 0 ]; then
      if grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
        SUCCESS="true"
      elif grep -q "^TASK_FAILED:" "$STDOUT_FILE"; then
        FAIL_REASON="$(grep "^TASK_FAILED:" "$STDOUT_FILE" | head -1 | sed 's/^TASK_FAILED: //')"
      fi
    fi

    # 8. Update SQLite using enhanced finalization with verification
    local FINAL_COMMENT=""
    local COMPLETION_SUCCESS="false"
    if [ "$SUCCESS" = "true" ]; then
      # Enhanced task completion with verification
      if complete_task_with_verification "$COMMENT_ID"; then
        COMPLETION_SUCCESS="true"
      else
        log "ERROR: Enhanced task completion failed for $COMMENT_ID, falling back to basic completion"
        # Fallback: attempt direct completion with ownership verification
        local fallback_pid
        fallback_pid="$(get_daemon_pid)"
        local fallback_result
        fallback_result="$(sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt=datetime('now') WHERE commentId='$safe_comment_id' AND workerPid=$fallback_pid; SELECT changes();" 2>/dev/null)"
        local fallback_changes
        fallback_changes="$(echo "$fallback_result" | tail -n 1)"
        if [ "${fallback_changes:-0}" -eq 1 ]; then
          # Verify the row is actually completed
          local verify_status
          verify_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
          if [ "$verify_status" = "completed" ]; then
            COMPLETION_SUCCESS="true"
            log "SUCCESS: Task $COMMENT_ID completed via fallback path"
          else
            log "ERROR: Fallback completion failed verification (status=$verify_status)"
          fi
        else
          log "ERROR: Fallback completion failed (changes=$fallback_changes)"
        fi
      fi

      if [ "$COMPLETION_SUCCESS" = "true" ]; then
        FINAL_COMMENT="✅ Manul completed the task successfully."
        log "dispatch: task $COMMENT_ID completed successfully"
      else
        FINAL_COMMENT="❌ Manul completed the work but failed to update task state."
        log "ERROR: task $COMMENT_ID finalization failed - SQLite update did not succeed"
      fi
    else
      # Re-read attempts from DB to ensure accuracy
      local NEW_ATTEMPTS
      NEW_ATTEMPTS="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null || echo "0")"
      local MAX_ATTEMPTS
      MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // 3' "$CONFIG" 2>/dev/null || echo 3)"

      if [ "${NEW_ATTEMPTS:-0}" -ge "$MAX_ATTEMPTS" ]; then
        sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$safe_comment_id';" 2>/dev/null
        FINAL_COMMENT="❌ Manul failed to complete the task after $NEW_ATTEMPTS attempts.${FAIL_REASON:+ Reason: $FAIL_REASON}"
        log "dispatch: task $COMMENT_ID failed (max attempts reached)"
      else
        sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL WHERE commentId='$safe_comment_id';" 2>/dev/null
        FINAL_COMMENT="⚠️ Manul encountered an issue and will retry (attempt $NEW_ATTEMPTS/$MAX_ATTEMPTS).${FAIL_REASON:+ Reason: $FAIL_REASON}"
        log "dispatch: task $COMMENT_ID requeued for retry (attempt $NEW_ATTEMPTS)"
      fi
    fi

    # Stop heartbeat after task completion/failure
    stop_heartbeat "$COMMENT_ID"

    # 9. Post final result comment to the SAME GitHub thread
    if [ -n "$FINAL_COMMENT" ]; then
      post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" || log "WARN: failed to post final comment for $COMMENT_ID"
    fi

    # Release repository lock
    release_repo_lock "$REPO"

    # Cleanup task workspace
    rm -rf "$TASK_WORKDIR"

    release_task_lock
  fi
}

loop() {
  log "daemon loop started (interval ${INTERVAL}s)"
  while true; do
    run_once
    sleep "$INTERVAL"
  done
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  run-once) run_once ;;
  loop) loop ;;
  *) echo "usage: $0 start|stop|status|run-once" >&2; exit 2 ;;
esac

