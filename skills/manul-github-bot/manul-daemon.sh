#!/usr/bin/bash
set -uo pipefail  # 'u' causes errors on unbound variables, 'o pipefail' catches pipeline errors
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
# ERR trap: log any unhandled command failure with context
trap 'echo "[$(date -Is)] FATAL_ERR line=$LINENO cmd=$BASH_COMMAND rc=$?" >> "$LIFECYCLE_LOG" 2>/dev/null' ERR

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
LIFECYCLE_LOG="$MANUL_DIR/lifecycle.log"
LAST_POLL_FILE="$MANUL_DIR/last-poll"
CURRENT_ACTIVITY_FILE="$MANUL_DIR/current_activity"
LOCK="$MANUL_DIR/lock"
FLOCK_FILE="$MANUL_DIR/daemon.flock"
# DB on native ext4 (NOT on 9p /mnt/f)
DB="/home/marzec/.openclaw/manul/manul.db"
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
CFG_LOCK_TTL="$(jq -r '.automation.lockTtl // empty' "$CONFIG" 2>/dev/null)"
LOCK_TTL="${MANUL_LOCK_TTL_SECONDS:-${CFG_LOCK_TTL:-1800}}"
CFG_RETRY_DELAY="$(jq -r '.retryConfig.delaySeconds // 60' "$CONFIG" 2>/dev/null || echo "60")"
RETRY_DELAY_SECONDS="${MANUL_RETRY_DELAY_SECONDS:-${CFG_RETRY_DELAY:-60}}"

log() { echo "[$(date -Is)] $*" >>"$LOG"; }

# Lifecycle event logger — structured, machine-parsable, human-readable
lc_log() {
  local event="$1"
  shift
  echo "[$(date -Is)] $event ${*:-}" >>"$LIFECYCLE_LOG"
}

# Update current activity state file
set_activity() {
  local task_id="${1:-none}"
  local activity="${2:-idle}"
  echo "${task_id}|${activity}|$(date -Is)" >"$CURRENT_ACTIVITY_FILE" 2>/dev/null || true
}

# Record last poll timestamp and result
record_poll() {
  local fire="${1:-false}"
  local new="${2:-0}"
  local pending="${3:-0}"
  printf '{"fire":%s,"new":%s,"pending":%s,"timestamp":"%s"}\n' \
    "$fire" "$new" "$pending" "$(date -Is)" >"$LAST_POLL_FILE" 2>/dev/null || true
  echo "${fire}|${new}|${pending}|$(date -Is)" >>"$LIFECYCLE_LOG"
}

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
  local repo_dir="${MANUL_DIR}/workspace/$repo_slug"
  local lockfile="${MANUL_DIR}/repo-locks/${repo_slug}.lock"

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
  local lockfile="${REPO_LOCK_DIR:-${MANUL_DIR}/repo-locks}/${slug}.lock"

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
      # Allow completion if already completed (idempotent)
      if [ "$current_status" = "completed" ]; then
        log "SUCCESS: Task $comment_id already completed (idempotent)"
        return 0
      fi
      # Allow completion if currently queued (race condition recovery)
      if [ "$current_status" = "queued" ]; then
        log "WARN: Task $comment_id was requeued during processing, completing anyway"
      elif [ "$current_status" != "running" ]; then
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

  # Verify heartbeat is stopped (no running heartbeat from a different process)
  # Note: heartbeat PID file may contain this daemon's own PID (from start_heartbeat using $$)
  # In that case, the heartbeat is managed by this daemon and is not a separate process
  local heartbeat_pid
  heartbeat_pid="$(cat "$MANUL_DIR/task-${comment_id}.heartbeat.pid" 2>/dev/null)"

  if [ -n "$heartbeat_pid" ] && [ "$heartbeat_pid" != "$(get_daemon_pid)" ]; then
    # Heartbeat belongs to a different process - check if it's still running
    if kill -0 "$heartbeat_pid" 2>/dev/null; then
      log "ERROR: Task $comment_id still has a running heartbeat (pid: $heartbeat_pid)"
      return 1
    fi
  fi
  # If heartbeat_pid is empty or equals daemon PID, heartbeat is considered stopped

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
  # Write PID file for verification
  echo "$pid" > "$MANUL_DIR/task-${comment_id}.heartbeat.pid" 2>/dev/null || true
  log "started heartbeat for task $comment_id (pid $pid)"
  lc_log "HEARTBEAT_START" "task=$comment_id pid=$pid interval=${HEARTBEAT_INTERVAL}s"
}

stop_heartbeat() {
  local comment_id="$1"
  unset HEARTBEAT_PIDS["$comment_id"]
  rm -f "$MANUL_DIR/task-${comment_id}.heartbeat.pid" 2>/dev/null || true
  log "stopped heartbeat for task $comment_id"
  lc_log "HEARTBEAT_STOP" "task=$comment_id"
}

# Refresh heartbeatAt in database to prevent watchdog timeout
refresh_heartbeat() {
  local comment_id="$1"
  if [ -n "${HEARTBEAT_PIDS[$comment_id]:-}" ]; then
    sqlite3 "$DB" "UPDATE processed_comments SET heartbeatAt=datetime('now') WHERE commentId='$comment_id' AND status='running';" 2>/dev/null || true
  fi
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

  # Clean up stale .daemon-lock if present from previous crashed/reboot session
  if [ -d "$MANUL_DIR/.daemon-lock" ]; then
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -c %Y "$MANUL_DIR/.daemon-lock" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -ge "$LOCK_TTL" ]; then
      log "stale .daemon-lock detected (age=${lock_age}s, ttl=${LOCK_TTL}s) → removing"
      rm -rf "$MANUL_DIR/.daemon-lock" 2>/dev/null
    else
      log ".daemon-lock is fresh (age=${lock_age}s); skipping cleanup"
    fi
  fi

  # Atomically write PID file under flock to prevent concurrent start races
  exec 200>"$FLOCK_FILE"
  flock -n 200 || { echo "cannot acquire lock (another start in progress)" >&2; return 1; }
  setsid nohup "$0" loop >>"$LOG" 2>&1 &
  local new_pid=$!
  echo "$new_pid" >"$PID_FILE"
  flock -u 200
  lc_log "DAEMON_START" "pid=$new_pid interval=${INTERVAL}s"
  echo "manul daemon started (pid $new_pid, interval ${INTERVAL}s)"
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
  lc_log "DAEMON_STOP" "pid=$pid"
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

# Ensure nextAttemptAt column exists in processed_comments
# Idempotent: safe to call multiple times, works on fresh and existing DBs
ensure_nextattemptat_column() {
  local has_column
  has_column="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -c '|nextAttemptAt|' || echo "0")"
  if [ "$has_column" -eq 0 ]; then
    log "migration: adding nextAttemptAt column to processed_comments"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;" 2>>"$LOG" || {
      log "ERROR: failed to add nextAttemptAt column"
      return 1
    }
    # Initialize existing queued retry tasks (attempts > 0) with a sensible backoff
    sqlite3 "$DB" "UPDATE processed_comments SET nextAttemptAt = datetime('now', '+60 seconds') WHERE status='queued' AND attempts > 0 AND nextAttemptAt IS NULL;" 2>>"$LOG" || {
      log "ERROR: failed to initialize nextAttemptAt for existing retries"
      return 1
    }
    log "migration: nextAttemptAt column added and initialized"
  fi
  return 0
}

post_github_comment() {
  local repo="$1"
  local issue="$2"
  local body="$3"
  local reply_to="${4:-}"

  # Append Manul signature to automated comments (deterministic)
  # Format: body\n\n— manul 🐈
  # Prevent duplicate signature if body already ends with it
  local signature="— manul 🐈"
  local signed_body
  if [[ "$body" == *"$signature" ]]; then
    signed_body="$body"
  else
    signed_body="${body}"$'\n\n'"$signature"
  fi

  if [ -n "$reply_to" ]; then
    # Review-thread task: reply inside the review thread via gh api
    # (gh pr comment --in-reply-to is not supported by gh CLI)
    gh api "repos/$repo/pulls/$issue/comments" \
      -F "body=$signed_body" \
      --field "in_reply_to=$reply_to" 2>>"$LOG"
  else
    # Top-level issue/PR-conversation task: post as a regular comment
    gh issue comment "$issue" --repo "$repo" --body "$signed_body" 2>>"$LOG"
  fi
}

# Verify the agent posted a result comment to GitHub for THIS exact task/attempt.
# Uses deterministic task/attempt marker: <!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->
# Fails closed on any error (missing commentUrl, API failure, no matching comment).
# Rejects lifecycle comments (🔄, ✅, ❌, ⚠️) — they share the signature but lack the marker.
verify_result_comment() {
  local repo="$1"
  local issue="$2"
  local comment_id="$3"
  local safe_comment_id="$4"
  local attempt="$5"

  # Get the task's commentUrl for correlation
  local comment_url
  comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ -z "$comment_url" ]; then
    log "ERROR: verify_result_comment: missing commentUrl for task $comment_id — fail-closed"
    lc_log "RESULT_VERIFY_ERROR" "task=$comment_id reason=missing_commentUrl"
    return 1
  fi

  # Extract issue/PR number from commentUrl
  local url_issue_num
  url_issue_num="$(printf '%s' "$comment_url" | grep -oE '(issues|pull)/[0-9]+' | grep -oE '[0-9]+' || echo "")"
  if [ -z "$url_issue_num" ]; then
    log "ERROR: verify_result_comment: could not extract issue number from commentUrl=$comment_url — fail-closed"
    lc_log "RESULT_VERIFY_ERROR" "task=$comment_id reason=unextractable_issue_number"
    return 1
  fi

  # Deterministic task/attempt marker
  local marker
  marker="<!-- manul-task:${comment_id}:attempt:${attempt} -->"

  # Query all Manul comments; filter for author and marker
  # Use jq to extract body directly from author-filtered results
  local result_count
  result_count=$(gh api "repos/$repo/issues/$url_issue_num/comments" \
    --jq '.[] | select(.in_reply_to_id == null) | .body // "" | gsub("\n"; "\\n")' \
    2>>"$LOG" | while IFS= read -r body; do
      # Exclude lifecycle comments (daemon posts these with same author/signature)
      # Reject lifecycle comments based on structural prefix (starts with emoji)
      # A valid result may contain these emojis in its body, but lifecycle comments
      # always start with them immediately (e.g., "✅ Manul completed...")
      if [[ "$body" == '🔄'* ]] || [[ "$body" == '✅'* ]] || [[ "$body" == '❌'* ]] || [[ "$body" == '⚠️'* ]]; then
        continue
      fi
      # Require exact deterministic marker
      if [[ "$body" == *"$marker"* ]]; then
        echo "found"
      fi
    done | wc -l)

  if [ "$result_count" -eq 1 ]; then
    log "verify_result_comment: found result comment for task $comment_id attempt $attempt on $repo#$url_issue_num"
    return 0
  fi

  # Also check for reply comments (in_reply_to matches a known Manul lifecycle comment)
  local reply_count
  reply_count=$(gh api "repos/$repo/issues/$url_issue_num/comments" \
    --jq '.[] | select(.in_reply_to_id != null) | .body // "" | gsub("\n"; "\\n")' \
    2>>"$LOG" | while IFS= read -r body; do
      # Reject lifecycle comments based on structural prefix (starts with emoji)
      if [[ "$body" == '🔄'* ]] || [[ "$body" == '✅'* ]] || [[ "$body" == '❌'* ]] || [[ "$body" == '⚠️'* ]]; then
        continue
      fi
      # Require exact deterministic marker
      if [[ "$body" == *"$marker"* ]]; then
        echo "found"
      fi
    done | wc -l)

  if [ "$reply_count" -eq 1 ]; then
    log "verify_result_comment: found reply result comment for task $comment_id attempt $attempt on $repo#$url_issue_num"
    return 0
  fi

  log "ERROR: verify_result_comment: no result comment with marker '$marker' found for task $comment_id attempt $attempt on $repo#$url_issue_num"
  lc_log "MISSING_RESULT_COMMENT" "task=$comment_id repo=$repo issue=$url_issue_num attempt=$attempt"
  return 1
}


run_once() {
  local out
  out="$("$POLL")"
  echo "$out"
  # Record poll result for observability
  local poll_fire poll_new poll_pending
  # Strip MANUL_RESULT prefix if present (poll.sh outputs "MANUL_RESULT {json}")
  local json_out="${out#MANUL_RESULT }"
  poll_fire="$(printf '%s' "$json_out" | jq -r '.fire // false' 2>/dev/null || echo false)"
  poll_new="$(printf '%s' "$json_out" | jq -r '.new // 0' 2>/dev/null || echo 0)"
  poll_pending="$(printf '%s' "$json_out" | jq -r '.pending // 0' 2>/dev/null || echo 0)"
  record_poll "$poll_fire" "$poll_new" "$poll_pending"

  if [ "$poll_fire" = "true" ]; then
    log "dispatch: $out"
    lc_log "POLL" "fire=true new=$poll_new pending=$poll_pending"
  else
    lc_log "POLL" "fire=false new=$poll_new pending=$poll_pending"
  fi

  if [ "$poll_fire" != "true" ]; then
    return 0
  fi

    # 0. Acquire singleton lock BEFORE any claim to prevent concurrent daemon races
    if ! acquire_task_lock; then
      log "dispatch: could not acquire lock, skipping"
      lc_log "LOCK_FAIL" "could_not_acquire"
      return 0
    fi

    # 1. Find next eligible task using proper SQLite query with retry backoff
    # Query only the fields we need, not the prompt (which may contain |)
    local TASK_INFO
    TASK_INFO="$(sqlite3 "$DB" "SELECT commentId, repository, issueNumber, attempts FROM processed_comments WHERE status='queued' AND (attempts=0 OR nextAttemptAt <= datetime('now')) ORDER BY nextAttemptAt ASC NULLS LAST, createdAt ASC LIMIT 1;" 2>/dev/null)"

    if [ -z "$TASK_INFO" ]; then
      log "dispatch: fire:true but no eligible queued task found"
      lc_log "NO_TASK" "fire=true but_queue_empty"
      release_task_lock
      return 0
    fi

    # Safe parsing: only three simple fields separated by |
    local COMMENT_ID REPO ISSUE_NUM ATTEMPTS
    IFS='|' read -r COMMENT_ID REPO ISSUE_NUM ATTEMPTS <<< "$TASK_INFO"
    [ -n "$COMMENT_ID" ] || { release_task_lock; return 0; }

    # 0.5 Completed-task guard - check if GitHub trigger is already completed
    # This must run AFTER TASK_INFO parsing so COMMENT_ID, REPO, ISSUE_NUM are available
    # Uses deterministic correlation via commentUrl to identify exact task completion
    local safe_comment_id_for_guard
    safe_comment_id_for_guard="$(sql_escape "$COMMENT_ID")"
    local safe_comment_url_for_guard
    safe_comment_url_for_guard="$(sql_escape "$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id_for_guard';" 2>/dev/null)")"

    if [ -n "$safe_comment_url_for_guard" ]; then
      # Check if this exact task is already completed by commentId
      local already_completed
      already_completed="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='$safe_comment_id_for_guard' AND status='completed';" 2>/dev/null || echo "0")"

      if [ "$already_completed" -gt 0 ]; then
        log "dispatch: task $COMMENT_ID already completed (duplicate detected via commentId), consuming safely"
        lc_log "DUPLICATE_COMPLETE" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM reason=already_completed"
        # Mark as completed to consume the duplicate without losing history
        sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt=datetime('now') WHERE commentId='$safe_comment_id_for_guard' AND status='queued';" 2>/dev/null
        release_task_lock
        set_activity "none" "idle"
        return 0
      fi

      # Also check if an equivalent task with same commentUrl was completed
      # This handles cases where the trigger was re-issued with a new commentId but same source
      local duplicate_by_url
      duplicate_by_url="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentUrl='$safe_comment_url_for_guard' AND status='completed';" 2>/dev/null || echo "0")"

      if [ "$duplicate_by_url" -gt 0 ]; then
        log "dispatch: task $COMMENT_ID already completed (duplicate detected via commentUrl), consuming safely"
        lc_log "DUPLICATE_COMPLETE" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM reason=by_url"
        sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt=datetime('now') WHERE commentId='$safe_comment_id_for_guard' AND status='queued';" 2>/dev/null
        release_task_lock
        set_activity "none" "idle"
        return 0
      fi
    else
      # GitHub lookup failed or commentUrl is empty - leave task queued and log error
      log "WARN: dispatch: could not retrieve commentUrl for task $COMMENT_ID, leaving queued"
      lc_log "GUARD_ERROR" "task=$COMMENT_ID reason=missing_comment_url"
    fi

    # Escape for SQL
    local safe_comment_id
    safe_comment_id="$(sql_escape "$COMMENT_ID")"
    local safe_repo
    safe_repo="$(sql_escape "$REPO")"
    # Initialize REPLY_TO early to prevent unbound variable errors
    local REPLY_TO=""

    # Read actual attempts from database (authoritative source)
    local ACTUAL_ATTEMPTS
    ACTUAL_ATTEMPTS="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$safe_comment_id' AND status='queued';" 2>/dev/null || echo "0")"

    # Check max attempts BEFORE claiming (guard against watchdog recovery resetting attempts)
    local MAX_ATTEMPTS
    MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // 3' "$CONFIG" 2>/dev/null || echo 3)"
    if [ "${ACTUAL_ATTEMPTS:-0}" -ge "$MAX_ATTEMPTS" ]; then
      log "dispatch: task $COMMENT_ID already at max attempts ($ACTUAL_ATTEMPTS >= $MAX_ATTEMPTS), marking as failed"
      lc_log "TASK_MAX_ATTEMPTS" "task=$COMMENT_ID repo=$REPO attempts=$ACTUAL_ATTEMPTS max=$MAX_ATTEMPTS"
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), nextAttemptAt=NULL WHERE commentId='$safe_comment_id';" 2>/dev/null
      local FINAL_COMMENT="❌ Manul failed to complete the task after $ACTUAL_ATTEMPTS attempts (max reached)."
      post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" "$REPLY_TO" || log "WARN: failed to post final comment for $COMMENT_ID"
      release_task_lock
      set_activity "none" "idle"
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
      lc_log "CLAIM_FAIL" "task=$COMMENT_ID changed=$CHANGED"
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
    lc_log "CLAIMED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempts=$((ACTUAL_ATTEMPTS + 1))"
    local current_attempt=$((ACTUAL_ATTEMPTS + 1))
    set_activity "$COMMENT_ID" "claimed"

    # Start heartbeat for long-running task
    start_heartbeat "$COMMENT_ID"
    # Refresh heartbeat immediately so watchdog doesn't see stale timestamp
    refresh_heartbeat "$COMMENT_ID"

    # 4. Post "in progress" comment BEFORE invoking the LLM
    # Gather task metadata for an informative status comment
    local TRIGGERER="$AUTHOR"
    local SOURCE_LINK="$COMMENT_URL"
    local TASK_SUMMARY
    TASK_SUMMARY="$(printf '%s' "$TASK_PROMPT" | head -1 | cut -c1-80)"
    local IN_PROGRESS_BODY="🔄 Manul is working on this task...

**Summary:** $TASK_SUMMARY
**Triggered by:** $TRIGGERER
**Source:** $SOURCE_LINK"

    if ! post_github_comment "$REPO" "$ISSUE_NUM" "$IN_PROGRESS_BODY" "$REPLY_TO"; then
      log "dispatch: FAILED to post in-progress comment for $COMMENT_ID, reverting to queued"
      lc_log "TASK_ERROR" "task=$COMMENT_ID reason=comment_post_failed"
      stop_heartbeat "$COMMENT_ID"
      sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE commentId='$safe_comment_id';" 2>/dev/null
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi

    log "dispatch: posted in-progress comment for $COMMENT_ID"

    # 5. Create per-task prompt containing the actual task payload
    local TASK_PROMPT_DIR="$MANUL_DIR/tasks"
    mkdir -p "$TASK_PROMPT_DIR"
    local TASK_PROMPT_FILE="$TASK_PROMPT_DIR/task-${COMMENT_ID}.md"

    # Determine task type from commentUrl metadata (do NOT call gh pr view)
    local TASK_TYPE="issue"
    local PR_HEAD_BRANCH=""
    if [[ "$COMMENT_URL" == *"/pull/"* ]]; then
      if [[ "$COMMENT_URL" == *"#discussion_r"* ]]; then
        TASK_TYPE="pr_review_comment"
        # Extract numeric review comment ID from commentId prefix (review:<id>)
        REPLY_TO="${COMMENT_ID#review:}"
      else
        TASK_TYPE="pr_conversation_comment"
      fi
      # Extract PR number from URL for branch resolution
      PR_NUM_FROM_URL="$(printf '%s' "$COMMENT_URL" | grep -oE 'pull/[0-9]+' | grep -oE '[0-9]+' || echo "")"
      if [ -n "$PR_NUM_FROM_URL" ] && [ "$PR_NUM_FROM_URL" != "$ISSUE_NUM" ]; then
        ISSUE_NUM="$PR_NUM_FROM_URL"
      fi
      # Fetch PR head branch for PR-tied tasks
      if [ -n "$PR_NUM_FROM_URL" ]; then
        PR_HEAD_BRANCH="$(gh pr view "$ISSUE_NUM" --repo "$REPO" --json headRefName --jq '.headRefName // ""' 2>>"$LOG" || echo "")"
      fi
    fi

    cat > "$TASK_PROMPT_FILE" <<'PROMPT_EOF'
# Manul Task:

You are the Manul implementation agent. Complete ONE task and then emit exactly one of the completion markers.

## Task
- Repository: __REPO__
- Issue/PR: #__ISSUE_NUM__
- Comment ID: __COMMENT_ID__
- Comment URL: __COMMENT_URL__
- Task Type: __TASK_TYPE__

## User Request
PROMPT_EOF

    # Append multiline task prompt (literal, no shell expansion)
    printf '%s\n' "$TASK_PROMPT" >> "$TASK_PROMPT_FILE"

    cat >> "$TASK_PROMPT_FILE" <<'PROMPT_EOF'

## Context
PROMPT_EOF

    # Append multiline task context (literal, no shell expansion)
    printf '%s\n' "$TASK_CONTEXT" >> "$TASK_PROMPT_FILE"

    cat >> "$TASK_PROMPT_FILE" <<'PROMPT_EOF'
## Command Intent Guidance
Before taking any action, determine whether this task is:
- **Informational**: The user is asking a question, requesting an explanation, or seeking advice. Reply with a thoughtful answer via GitHub comment. Do NOT modify any repository files.
- **Repository Change**: The user wants code changes, fixes, features, or other modifications. Proceed with implementation on the appropriate branch.

If the task is informational, you MUST post a thoughtful answer as a GitHub comment using the `run` tool (see GitHub Comment Posting section below), then emit `TASK_DONE`. Do NOT modify any repository files.

## Rules
1. Inspect the local repository and implement the requested change.
2. Run appropriate tests/validation.
3. Make the requested code changes.
4. When finished, output exactly: `TASK_DONE`
5. If you cannot complete the task, output exactly: `TASK_FAILED: <brief reason>`
6. Do NOT modify `manul.db`.
7. Do NOT manage Manul task state.

## GitHub Comment Posting (CRITICAL)
You MUST post exactly one user-facing result comment to GitHub using the `run` tool:

```bash
gh api repos/__REPO__/issues/__ISSUE_NUM__/comments \
  -f body="YOUR_RESULT_COMMENT" \
  --jq .id
```

Replace REPO, ISSUE_NUM, and YOUR_RESULT_COMMENT with actual values.
Use the in_reply_to parameter if this is a reply:
```bash
gh api repos/__REPO__/issues/__ISSUE_NUM__/comments \
  -f body="YOUR_REPLY" \
  -f in_reply_to=ORIGINAL_COMMENT_ID \
  --jq .id
```

Your comment MUST:
- Start with the task summary
- Include the deterministic task/attempt marker: `<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->`
- Include your actual work/output
- End with: "— manul 🐈"
- Be posted BEFORE emitting TASK_DONE

Example informational task response:
```
<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->
# Available Skills

[Your skill listing here]

— manul 🐈
```

The daemon handles lifecycle comments (🔄 working, ✅ completed, ❌ failed).
You handle the result comment.
PROMPT_EOF

    # Repository Management: Ensure target repository exists and is authoritative
    local REPO_DIR
    REPO_DIR="$(ensure_repo "$REPO")"
    if [ $? -ne 0 ]; then
      log "dispatch: FAILED to ensure repository $REPO, failing task"
      lc_log "TASK_ERROR" "task=$COMMENT_ID reason=repo_unavailable repo=$REPO"
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), nextAttemptAt=NULL WHERE commentId='$safe_comment_id';" 2>/dev/null
      local FINAL_COMMENT="❌ Manul failed to access the repository $REPO."
      post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" "$REPLY_TO" || log "WARN: failed to post final comment for $COMMENT_ID"
      stop_heartbeat "$COMMENT_ID"
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi

    # Verify repository integrity
    if ! verify_repo "$REPO" "$REPO_DIR"; then
      log "dispatch: REPOSITORY VERIFICATION FAILED for $REPO, failing task"
      lc_log "TASK_ERROR" "task=$COMMENT_ID reason=repo_verification_failed repo=$REPO"
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), nextAttemptAt=NULL WHERE commentId='$safe_comment_id';" 2>/dev/null
      local FINAL_COMMENT="❌ Manul repository verification failed for $REPO."
      post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" "$REPLY_TO" || log "WARN: failed to post final comment for $COMMENT_ID"
      stop_heartbeat "$COMMENT_ID"
      release_repo_lock "$REPO"
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi

    # 6. Set working directory to the repository root
    local WORKDIR="$REPO_DIR"

    log "dispatch: task $COMMENT_ID repository located at $REPO_DIR"

    # Generate timestamp for unique branch name
    local timestamp
    timestamp="$(date +%s)"

    # Compute current/default branches safely (avoid command substitution in heredoc)
    local CURRENT_BRANCH
    CURRENT_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "UNKNOWN")"
    local DEFAULT_BRANCH
    DEFAULT_BRANCH="$(git -C "$REPO_DIR" remote show origin 2>/dev/null | grep "HEAD" | awk '{print $3}' || echo "master")"

    # Update prompt to include authoritative repository path and branch policy
    cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'

## Authoritative Repository
The target repository for this task is located at: __REPO_DIR__

## Working Directory
You will execute in the repository directory:
__WORKDIR__

## Branch Policy
PROMPT_APPEND

    if [ -n "$PR_HEAD_BRANCH" ]; then
      # PR-tied task: operate on the PR's head branch
      cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'
- This task is tied to PR #__ISSUE_NUM__
- PR head branch: `__PR_HEAD_BRANCH__`
- Switch to the PR head branch (`git checkout __PR_HEAD_BRANCH__`) before making any changes
- Commit and push changes to the same PR head branch
- Do NOT create a new branch for this task
PROMPT_APPEND
    else
      # Issue or non-PR task: create a dedicated task branch
      cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'
- This is a standalone task (not tied to an existing PR)
- Current branch: __CURRENT_BRANCH__
- Default branch: __DEFAULT_BRANCH__
- Create a dedicated task branch from the default branch BEFORE making any changes
- Branch name format: `manul-task-__COMMENT_ID__-__TIMESTAMP__`
- Do NOT make any repository changes while on the default branch
- After completing changes, commit and push to your task branch
PROMPT_APPEND
    fi

    cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'

## Skills
Your skills are available at: ~/.agents/skills
Use relevant skills when appropriate to guide your implementation.
PROMPT_APPEND

    # Substitute all single-line placeholders with actual runtime values
    # Using bash parameter expansion (safe: replacement is literal, no command substitution)
    local prompt_content
    prompt_content="$(cat "$TASK_PROMPT_FILE")"
    prompt_content="${prompt_content//__REPO__/$REPO}"
    prompt_content="${prompt_content//__ISSUE_NUM__/$ISSUE_NUM}"
    prompt_content="${prompt_content//__COMMENT_ID__/$COMMENT_ID}"
    prompt_content="${prompt_content//__COMMENT_URL__/$COMMENT_URL}"
    prompt_content="${prompt_content//__TASK_TYPE__/$TASK_TYPE}"
    prompt_content="${prompt_content//__CURRENT_ATTEMPT__/$current_attempt}"
    prompt_content="${prompt_content//__REPO_DIR__/$REPO_DIR}"
    prompt_content="${prompt_content//__WORKDIR__/$WORKDIR}"
    prompt_content="${prompt_content//__PR_HEAD_BRANCH__/$PR_HEAD_BRANCH}"
    prompt_content="${prompt_content//__TIMESTAMP__/$timestamp}"
    prompt_content="${prompt_content//__CURRENT_BRANCH__/$CURRENT_BRANCH}"
    prompt_content="${prompt_content//__DEFAULT_BRANCH__/$DEFAULT_BRANCH}"
    printf '%s' "$prompt_content" > "$TASK_PROMPT_FILE"

    # 6. Invoke implementation agent with the per-task prompt, ensuring proper working directory
    local STDOUT_FILE="$MANUL_DIR/tasks/task-${COMMENT_ID}.stdout"
    local STDERR_FILE="$MANUL_DIR/tasks/task-${COMMENT_ID}.stderr"

    log "dispatch: invoking agent manul for task $COMMENT_ID"
    lc_log "WORKER_START" "task=$COMMENT_ID repo=$REPO timeout=${AGENT_TIMEOUT}s"
    set_activity "$COMMENT_ID" "working"

     # Change to repository directory and invoke agent
     local prev_dir
     prev_dir="$(pwd)"
     cd "$WORKDIR" || { log "ERROR: cannot enter working directory $WORKDIR, failing task"; return 1; }
     # Ensure skill visibility for the OpenCode process
     export OPENCODE_SKILLS_PATH="$HOME/.agents/skills"
     # Refresh heartbeat before agent to prevent timeout during long runs
     refresh_heartbeat "$COMMENT_ID"
     timeout -k 60 "$AGENT_TIMEOUT" "$OPENCLAW_BIN" agent --agent main --message-file "$TASK_PROMPT_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE"
     local rc=$?
     cd "$prev_dir" 2>/dev/null || log "WARN: failed to restore working directory"
     # Refresh heartbeat after agent completes (if still running)
     refresh_heartbeat "$COMMENT_ID"

    log "dispatch: agent finished rc=$rc for task $COMMENT_ID"
    lc_log "WORKER_FINISH" "task=$COMMENT_ID rc=$rc"

    # 7. Determine success using BOTH exit status AND explicit completion marker
    local SUCCESS="false"
    local FAIL_REASON=""

    if [ $rc -eq 0 ]; then
      if [ -f "$STDOUT_FILE" ] && grep -qE 'TASK_DONE|TASK_COMPLETED' "$STDOUT_FILE"; then
        SUCCESS="true"
      elif [ -f "$STDOUT_FILE" ] && grep -qE 'TASK_FAILED:' "$STDOUT_FILE"; then
        FAIL_REASON="$(grep -E 'TASK_FAILED:' "$STDOUT_FILE" | head -1 | sed -E 's/.*TASK_FAILED: //')"
      fi
    fi

    # 7.1 Daemon posts only lifecycle comments; agent posts result comment directly.
    # No extraction needed - agent handles its own GitHub communication.

    # 7.1 Verify agent posted result comment for THIS exact task/attempt before accepting TASK_DONE
    if [ "$SUCCESS" = "true" ]; then
      current_attempt=$((ACTUAL_ATTEMPTS + 1))
      if ! verify_result_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt"; then
        log "dispatch: task $COMMENT_ID attempt $current_attempt has no result comment — marking as failed"
        lc_log "MISSING_RESULT_COMMENT" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempt=$current_attempt"
        SUCCESS="false"
        FAIL_REASON="Agent emitted TASK_DONE but did not post a result comment with deterministic marker for attempt $current_attempt"
      fi
    fi

    # 7.5. Verify repository state is clean (no staged/unstaged/untracked changes)
    if [ "$SUCCESS" = "true" ] && [ -n "$REPO_DIR" ] && [ -d "$REPO_DIR/.git" ]; then
      local repo_state_clean="true"
      local repo_state_issues=""

      # Check for staged changes
      if ! git -C "$REPO_DIR" diff --cached --quiet 2>/dev/null; then
        repo_state_clean="false"
        repo_state_issues+="staged_changes "
      fi

      # Check for unstaged changes
      if ! git -C "$REPO_DIR" diff --quiet 2>/dev/null; then
        repo_state_clean="false"
        repo_state_issues+="unstaged_changes "
      fi

      # Check for untracked files
      local untracked
      untracked="$(git -C "$REPO_DIR" ls-files --others --exclude-standard 2>/dev/null)"
      if [ -n "$untracked" ]; then
        repo_state_clean="false"
        repo_state_issues+="untracked_files "
      fi

      if [ "$repo_state_clean" = "false" ]; then
        SUCCESS="false"
        FAIL_REASON="Repository has incomplete state: ${repo_state_issues% }"
        log "dispatch: task $COMMENT_ID repository verification failed (${repo_state_issues% })"
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
        lc_log "TASK_ERROR" "task=$COMMENT_ID reason=finalization_failed"
      fi
    else
      # Re-read attempts from DB to ensure accuracy
      local NEW_ATTEMPTS
      NEW_ATTEMPTS="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null || echo "0")"
      local MAX_ATTEMPTS
      MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // 3' "$CONFIG" 2>/dev/null || echo 3)"

      if [ "${NEW_ATTEMPTS:-0}" -ge "$MAX_ATTEMPTS" ]; then
        FINAL_COMMENT="❌ Manul failed to complete the task after $NEW_ATTEMPTS attempts.${FAIL_REASON:+ Reason: $FAIL_REASON}"
        log "dispatch: task $COMMENT_ID failed (max attempts reached)"
        lc_log "TASK_FAILED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempts=$NEW_ATTEMPTS max=$MAX_ATTEMPTS${FAIL_REASON:+ reason=$FAIL_REASON}"
      else
        FINAL_COMMENT="⚠️ Manul encountered an issue and will retry (attempt $NEW_ATTEMPTS/$MAX_ATTEMPTS).${FAIL_REASON:+ Reason: $FAIL_REASON}"
        log "dispatch: task $COMMENT_ID requeued for retry (attempt $NEW_ATTEMPTS)"
        lc_log "TASK_REQUEUED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempt=$NEW_ATTEMPTS max=$MAX_ATTEMPTS${FAIL_REASON:+ reason=$FAIL_REASON}"
      fi
    fi

    # 9. Post lifecycle comment to the SAME GitHub thread
    # The agent posts its own result comment; daemon posts lifecycle markers only.
    # CRITICAL: Post comment BEFORE marking task as completed in SQLite.
    local COMMENT_POST_SUCCESS="false"
    if [ -n "$FINAL_COMMENT" ]; then
      if post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" "$REPLY_TO"; then
        COMMENT_POST_SUCCESS="true"
      else
        log "ERROR: failed to post lifecycle comment for $COMMENT_ID"
      fi
    fi

    # Verify lifecycle comment was posted
    if [ "$COMPLETION_SUCCESS" = "true" ] && [ "$COMMENT_POST_SUCCESS" != "true" ]; then
      # Agent succeeded but lifecycle comment posting failed - still mark complete
      log "WARN: Task $COMMENT_ID agent succeeded but lifecycle comment post failed"
    elif [ "$COMPLETION_SUCCESS" = "true" ]; then
      # Both agent succeeded AND comment posted - finalize as completed
      # NOTE: Status was already set to 'completed' by complete_task_with_verification above
      set_activity "$COMMENT_ID" "completed"
    elif [ "${NEW_ATTEMPTS:-0}" -ge "$MAX_ATTEMPTS" ]; then
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), nextAttemptAt=NULL WHERE commentId='$safe_comment_id';" 2>/dev/null
    else
      sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE commentId='$safe_comment_id';" 2>/dev/null
    fi

    # Stop heartbeat after task completion/failure
    stop_heartbeat "$COMMENT_ID"
    lc_log "HEARTBEAT_STOP" "task=$COMMENT_ID"

    # Release repository lock
    release_repo_lock "$REPO"

    # Cleanup task artifacts (no separate workdir to remove)
    rm -f "$TASK_PROMPT_FILE" "$STDOUT_FILE" "$STDERR_FILE"

    release_task_lock
    set_activity "none" "idle"
}

loop() {
  # Ensure nextAttemptAt column exists before any scheduler query
  if ! ensure_nextattemptat_column; then
    log "FATAL: schema migration failed, cannot start loop"
    exit 1
  fi

  # Singleton enforcement: try to acquire flock; if another daemon holds it, exit
  exec 200>"$FLOCK_FILE"
  if ! flock -n 200; then
    log "daemon already running (flock held); exiting"
    exit 1
  fi
  # Lock held for lifetime of daemon process

  log "daemon loop started (interval ${INTERVAL}s)"
  lc_log "LOOP_START" "interval=${INTERVAL}s"
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

