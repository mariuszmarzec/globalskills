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
# ERR trap: log any unhandled command failure with context
trap 'if [[ $BASH_COMMAND != "return "* ]] && [[ $BASH_COMMAND != *"|| true"* ]]; then echo "[$(date -Is)] FATAL_ERR line=$LINENO cmd=$BASH_COMMAND rc=$?" >> "${LIFECYCLE_LOG:-/dev/null}" 2>/dev/null; fi' ERR

# Ensure standard PATH is available when running via setsid/nohup.
# ~/.local/bin is required: the OpenClaw CLI is installed there and the daemon
# (often started by cron/watchdog) inherits a PATH that omits it, which made
# `command -v openclaw` fail and every agent invocation die instantly.
# The OpenClaw CLI itself is a wrapper that execs `npx`, so the nvm node bin
# must also be reachable or the agent dies with "npx: not found".
# NOTE: the nvm glob must be expanded BEFORE assignment (unquoted), otherwise
# the literal string "*.bin" ends up on PATH and `npx` is still not found.
_NVM_NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | head -n1)"
export PATH="$HOME/.local/bin:${_NVM_NODE_BIN:-$HOME/.nvm/versions/node/current/bin}:/usr/local/bin:/usr/bin:/bin:$PATH"

# Ensure OpenClaw uses the native state directory (post-migration)
export OPENCLAW_STATE_DIR="/home/marzec/.openclaw-native/state"
export OPENCLAW_CONFIG_PATH="/home/marzec/.openclaw-native/openclaw.json"

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
# Absolute path to this script (the daemon is invoked via a symlink, so $0 may
# be relative). Workers are spawned with nohup/setsid and need a stable path.
DAEMON_SCRIPT_ABS="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "$0")"
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
DB="${MANUL_DIR}/manul.db"
CFG_INTERVAL="$(jq -r '.pollInterval // empty' "$CONFIG" 2>/dev/null)"
INTERVAL="${MANUL_INTERVAL:-${CFG_INTERVAL:-60}}"
CFG_AGENT_TIMEOUT="$(jq -r '.automation.agentTimeoutSeconds // 43500' "$CONFIG" 2>/dev/null)"
AGENT_TIMEOUT="${MANUL_AGENT_TIMEOUT:-${CFG_AGENT_TIMEOUT:-43500}}"   # full Manul agent turn; keep longer than OpenClaw's explicit inner timeout
POLL_TIMEOUT="${MANUL_POLL_TIMEOUT:-120}"      # seconds timeout for poll.sh
GH_API_TIMEOUT="${MANUL_GH_API_TIMEOUT:-30}"   # seconds timeout for gh api calls
OPENCLAW_BIN="$(command -v openclaw 2>/dev/null || echo "")"
export OPENCLAW_BIN

# Read heartbeat configuration from config.json
CFG_HEARTBEAT_INTERVAL="$(jq -r '.automation.heartbeatInterval // 60' "$CONFIG" 2>/dev/null)"
HEARTBEAT_INTERVAL="${MANUL_HEARTBEAT_INTERVAL:-${CFG_HEARTBEAT_INTERVAL:-60}}"
CFG_HEARTBEAT_TIMEOUT="$(jq -r '.automation.heartbeatTimeout // 900' "$CONFIG" 2>/dev/null)"
HEARTBEAT_TIMEOUT="${MANUL_HEARTBEAT_TIMEOUT:-${CFG_HEARTBEAT_TIMEOUT:-900}}"
CFG_LEASE_TIMEOUT="$(jq -r '.automation.leaseTimeout // 900' "$CONFIG" 2>/dev/null)"
LEASE_TIMEOUT="${MANUL_LEASE_TIMEOUT:-${CFG_LEASE_TIMEOUT:-900}}"
# Read concurrency configuration from config.json
CFG_MAX_CONCURRENT="$(jq -r '.automation.maxConcurrentTasks // 1' "$CONFIG" 2>/dev/null || echo 1)"
MAX_CONCURRENT_TASKS="${MANUL_MAX_CONCURRENT_TASKS:-${CFG_MAX_CONCURRENT:-1}}"
# Validate maxConcurrentTasks is a positive integer
if ! [[ "$MAX_CONCURRENT_TASKS" =~ ^[0-9]+$ ]] || [ "$MAX_CONCURRENT_TASKS" -lt 1 ]; then
  log "WARN: invalid maxConcurrentTasks ($MAX_CONCURRENT_TASKS), defaulting to 1"
  MAX_CONCURRENT_TASKS=1
fi
CFG_LOCK_TTL="$(jq -r '.automation.lockTtl // empty' "$CONFIG" 2>/dev/null)"
LOCK_TTL="${MANUL_LOCK_TTL_SECONDS:-${CFG_LOCK_TTL:-1800}}"
REPO_LOCK_TTL="${MANUL_REPO_LOCK_TTL_SECONDS:-${LOCK_TTL:-1800}}"
CFG_RETRY_DELAY="$(jq -r '.retryConfig.delaySeconds // 60' "$CONFIG" 2>/dev/null || echo "60")"
RETRY_DELAY_SECONDS="${MANUL_RETRY_DELAY_SECONDS:-${CFG_RETRY_DELAY:-60}}"

TASK_RETENTION_DEFAULT_LIST_DAYS=7
TASK_RETENTION_DEFAULT_HISTORY_DAYS=14
TASK_LIST_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_LIST_DAYS"
TASK_HISTORY_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_HISTORY_DAYS"

# Source operator overrides from ~/.openclaw/manul/.env if present.
  # This is what makes MANUL_POLL_TIMEOUT / MANUL_INTERVAL / etc. actually
  # take effect — without it the daemon ignores the .env file entirely and
  # falls back to hardcoded defaults (e.g. POLL_TIMEOUT=120s), which is too
  # short to cover one slow repository per poll cycle.
  if [ -f "$MANUL_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$MANUL_DIR/.env"
    set +a
  fi

  # Per-repo timeout, mirrored from poll.sh's default so the daemon's
  # scaled global poll timeout matches what poll.sh actually enforces.
  REPO_POLL_TIMEOUT="${MANUL_REPO_POLL_TIMEOUT:-60}"
  # Repository list, mirrored from poll.sh so run_once can size the global
  # poll timeout dynamically instead of assuming a fixed 120s.
  mapfile -t REPOS < <(jq -r '.repositories[]?' "$CONFIG" 2>/dev/null)

  log() { echo "[$(date -Is)] $*" >>"$LOG"; }
  configure_task_retention() {
    local list_days history_days
    list_days="$(jq -r '.retention.listDays // empty' "$CONFIG" 2>/dev/null || true)"
    history_days="$(jq -r '.retention.historyDays // empty' "$CONFIG" 2>/dev/null || true)"

    if ! [[ "$list_days" =~ ^[0-9]+$ ]] || [ "$list_days" -lt 1 ] || \
       ! [[ "$history_days" =~ ^[0-9]+$ ]] || [ "$history_days" -lt 1 ] || \
       [ "$history_days" -lt $((list_days * 2)) ]; then
      TASK_LIST_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_LIST_DAYS"
      TASK_HISTORY_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_HISTORY_DAYS"
      TASK_RETENTION_CONFIG_MESSAGE="WARN: invalid retention config (listDays=${list_days:-missing}, historyDays=${history_days:-missing}); using defaults listDays=$TASK_RETENTION_DEFAULT_LIST_DAYS, historyDays=$TASK_RETENTION_DEFAULT_HISTORY_DAYS"
    else
      TASK_LIST_RETENTION_DAYS="$list_days"
      TASK_HISTORY_RETENTION_DAYS="$history_days"
      TASK_RETENTION_CONFIG_MESSAGE="INFO: task retention configured (listDays=$TASK_LIST_RETENTION_DAYS, historyDays=$TASK_HISTORY_RETENTION_DAYS)"
    fi
  }


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


# Parse poll.sh output into exactly one normalized result.
# Never let malformed/multi-value jq output reach the dispatch gate.
parse_poll_result() {
  local out="${1:-}"
  local result_line json_out validated_json
  result_line="$(printf '%s\n' "$out" | grep '^MANUL_RESULT ' | tail -n 1 || true)"
  if [ -z "$result_line" ]; then
    printf 'false|0|0\n'
    return 0
  fi

  json_out="${result_line#MANUL_RESULT }"
  validated_json="$(printf '%s' "$json_out" | jq -e -c -s 'if length == 1 then .[0] | select(type == "object") else empty end' 2>/dev/null || true)"
  if [ -z "$validated_json" ]; then
    log "WARN: invalid MANUL_RESULT ignored"
    printf 'false|0|0\n'
    return 0
  fi

  local fire new pending
  fire="$(printf '%s' "$validated_json" | jq -r 'if .fire == true then "true" else "false" end')"
  new="$(printf '%s' "$validated_json" | jq -r 'if (.new|type) == "number" then .new else 0 end')"
  pending="$(printf '%s' "$validated_json" | jq -r 'if (.pending|type) == "number" then .pending else 0 end')"
  printf '%s|%s|%s\n' "$fire" "$new" "$pending"
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
  rm -f "${REPO_LOCK_DIR:-${MANUL_DIR}/repo-locks}/${slug}.lock"
}

# Enhanced SQLite UPDATE with verification and error handling
update_task_completion() {
  ensure_claim_token_column || return 1
  local comment_id="$1"
  local safe_comment_id="$(sql_escape "$comment_id")"
  local status="$2"
  local error_message="${3:-}"
  local claim_token="${4:-}"

  local task_exists
  task_exists="$(sqlite3 "$DB" "SELECT 1 FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
  if [ -z "$task_exists" ]; then
    log "ERROR: Task $comment_id does not exist in database"
    return 1
  fi

  local current_status
  current_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  case "$status" in
    completed|failed)
      if [ "$current_status" = "$status" ]; then
        log "SUCCESS: Task $comment_id already $status (idempotent)"
        return 0
      fi
      if [ "$current_status" != "running" ]; then
        log "ERROR: Cannot $status task $comment_id from current status: $current_status"
        return 1
      fi
      ;;
    queued)
      if [ "$current_status" != "running" ]; then
        log "ERROR: Cannot requeue task $comment_id from current status: $current_status"
        return 1
      fi
      ;;
    *)
      log "ERROR: Unsupported task completion status: $status"
      return 1
      ;;
  esac

  local where_clause="WHERE commentId='$safe_comment_id' AND status='running'"
  if [ -n "$claim_token" ]; then
    local safe_claim_token
    safe_claim_token="$(sql_escape "$claim_token")"
    where_clause+=" AND claimToken='$safe_claim_token'"
  else
    # Backward compatibility for rows created before claimToken existed.
    # Once a new claim has a token, an old execution without one cannot finalize it.
    local legacy_worker_pid="${BASHPID}"
    local db_claim_token
    db_claim_token="$(sqlite3 "$DB" "SELECT claimToken FROM processed_comments WHERE commentId='$safe_comment_id' AND status='running' LIMIT 1;" 2>/dev/null)"
    if [ -n "$db_claim_token" ]; then
      log "ERROR: Refusing legacy finalization for $comment_id because current claim has a token"
      return 1
    fi
    where_clause+=" AND workerPid=$legacy_worker_pid AND claimToken IS NULL"
  fi

  local update_sql="UPDATE processed_comments SET status='$status'"
  case "$status" in
    completed|failed)
      update_sql+=" , processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL"
      ;;
    queued)
      update_sql+=" , processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL"
      ;;
  esac

  local update_result
  update_result="$(sqlite3 "$DB" "$update_sql $where_clause; SELECT changes();" 2>/dev/null)"
  local changes
  changes="$(echo "$update_result" | tail -n 1)"

  if [ "${changes:-0}" -eq 1 ]; then
    log "SUCCESS: Task $comment_id transitioned to $status (previous: $current_status)"
    return 0
  fi
  log "ERROR: Task $comment_id update failed (changes=$changes, previous=$current_status)"
  return 1
}
# Finalization verification: ensure heartbeat and locks don't revert completion
# FIX: Stop any lingering heartbeat BEFORE verifying finalization.
# The old code compared heartbeat PID vs daemon PID and could fail when
# daemon.pid was missing (daemon started directly) or when the daemon's
# own heartbeat was still recorded.  Here we explicitly reap the heartbeat
# so finalization is never blocked by a still-running timer process.
verify_finalization() {
  local comment_id="$1"
  local safe_comment_id="$(sql_escape "$comment_id")"

  # ── Step 0: synchronously stop any heartbeat for this task ─────────────────
  # This must happen BEFORE we touch finalization state; the task must not
  # reach terminal status while its heartbeat is still alive.
  local heartbeat_pid
  heartbeat_pid="$(cat "$MANUL_DIR/task-${comment_id}.heartbeat.pid" 2>/dev/null)"

  if [ -n "$heartbeat_pid" ]; then
    if kill -0 "$heartbeat_pid" 2>/dev/null; then
      # Heartbeat is still running — terminate it and reap the exit status.
      # kill is idempotent for already-dead processes; kill -0 above confirmed liveness.
      kill "$heartbeat_pid" 2>/dev/null || true
      wait "$heartbeat_pid" 2>/dev/null || true
    fi
    # Remove the PID file unconditionally (idempotent; no-op if already gone).
    rm -f "$MANUL_DIR/task-${comment_id}.heartbeat.pid" 2>/dev/null || true
  fi

  # ── Step 1: verify task is completed in SQLite ─────────────────────────────
  local task_status
  task_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ "$task_status" != "completed" ]; then
    log "ERROR: Task $comment_id is not completed in SQLite (status: $task_status)"
    return 1
  fi

  # ── Step 2: verify processedAt is set ──────────────────────────────────────
  local processed_at
  processed_at="$(sqlite3 "$DB" "SELECT processedAt FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ -z "$processed_at" ] || [ "$processed_at" = "null" ]; then
    log "ERROR: Task $comment_id has no processedAt timestamp"
    return 1
  fi

  # ── Step 3: verify heartbeat PID file is gone (confirm we reaped it) ────────
  if [ -f "$MANUL_DIR/task-${comment_id}.heartbeat.pid" ]; then
    log "ERROR: Task $comment_id heartbeat PID file still present after shutdown"
    return 1
  fi

  # ── Step 4: verify workerPid is cleared ────────────────────────────────────
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
  local claim_token="${2:-}"

  # Mark task as completed with verification
  if ! update_task_completion "$comment_id" "completed" "" "$claim_token"; then
    log "ERROR: Failed to complete task $comment_id"
    return 1
  fi

  # Verify finalization
  if ! verify_finalization "$comment_id"; then
    # Path C: DB is already updated to 'completed' (the correct terminal state).
    # Verification failure is non-fatal — the task is done, we just couldn't
    # confirm all post-conditions. Report success so the daemon doesn't get
    # stuck retrying an already-completed task.
    log "WARNING: Finalization verification failed for task $comment_id but status is completed"
    return 0
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

# Recover tasks stuck in 'running' state due to daemon crash, deadlock, or process death.
# This handles cases where:
# 1. Worker process died but task still marked 'running'
# 2. Lease expired but task not finalized
# 3. Deadlocked pipe in verify_result_comment or similar
recover_stale_tasks() {
  ensure_claim_token_column || return 1
  log "recover_stale_tasks: checking for stuck tasks"
  lc_log "RECOVERY_START" ""

  local stale_tasks
  stale_tasks="$(sqlite3 "$DB" "
    SELECT commentId, repository, issueNumber, workerPid, leaseExpiresAt, attempts, claimToken
    FROM processed_comments
    WHERE status='running'
      AND (
        heartbeatAt IS NULL
        OR heartbeatAt < datetime('now', '-${HEARTBEAT_TIMEOUT} seconds')
        OR leaseExpiresAt IS NULL
        OR leaseExpiresAt < datetime('now')
      )
    LIMIT 100;" 2>/dev/null)"

  if [ -z "$stale_tasks" ]; then
    log "recover_stale_tasks: no stale tasks found"
    return 0
  fi

  local recovered=0
  while IFS='|' read -r comment_id repo issue_num worker_pid lease_expires attempts claim_token; do
    [ -n "$comment_id" ] || continue

    local worker_alive=0
    if [ -n "$worker_pid" ] && [ "$worker_pid" -gt 0 ] 2>/dev/null && kill -0 "$worker_pid" 2>/dev/null; then
      worker_alive=1
    fi
    log "recover_stale_tasks: stale task $comment_id (worker=$worker_pid alive=$worker_alive lease=$lease_expires attempts=$attempts)"

    local max_attempts
    max_attempts="$(jq -r '.automation.maxAttemptsBeforeFail // 3' "$CONFIG" 2>/dev/null || echo 3)"
    local safe_comment_id
    safe_comment_id="$(sql_escape "$comment_id")"
    local ownership_clause
    if [ -n "$claim_token" ]; then
      local safe_claim_token
      safe_claim_token="$(sql_escape "$claim_token")"
      ownership_clause="AND claimToken='$safe_claim_token'"
    else
      ownership_clause="AND claimToken IS NULL"
    fi

    if [ "${attempts:-0}" -ge "$max_attempts" ]; then
      log "recover_stale_tasks: marking stale task as failed: $comment_id"
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='running' $ownership_clause;" 2>/dev/null
      lc_log "TASK_FAILED" "task=$comment_id repo=$repo issue=$issue_num reason=stale_lease_max_attempts"
    else
      sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE commentId='$safe_comment_id' AND status='running' $ownership_clause;" 2>/dev/null
      log "recover_stale_tasks: requeued task $comment_id for retry (attempts preserved=$attempts)"
      lc_log "TASK_REQUEUED" "task=$comment_id repo=$repo issue=$issue_num attempts=$attempts reason=stale_lease"
    fi
    recovered=$((recovered + 1))
  done <<<"$stale_tasks"

  log "recover_stale_tasks: recovered $recovered stale task(s)"
  lc_log "RECOVERY_COMPLETE" "recovered=$recovered"
  return 0
}
# Per-task heartbeat child processes, keyed by comment/task id.
declare -A HEARTBEAT_PIDS

# Determine the base branch that a standalone task should start from.
# This mirrors feature-branching-strategy's preferred order for the initial
# workspace: develop -> master -> repository default branch. The agent may
# later choose a different, explicitly required base branch before branching.
determine_task_base_branch() {
  local workdir="$1"
  local default_branch="$2"
  if git -C "$workdir" show-ref --verify --quiet "refs/remotes/origin/develop"; then echo "develop"; return 0; fi
  if git -C "$workdir" show-ref --verify --quiet "refs/remotes/origin/master"; then echo "master"; return 0; fi
  if [ -n "$default_branch" ]; then echo "$default_branch"; return 0; fi
  default_branch="$(git -C "$workdir" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}' || true)"
  [ -n "$default_branch" ] && { echo "$default_branch"; return 0; }
  echo "master"
}

repository_changed_since() {
  local workdir="$1" initial_head="$2"
  [ -n "$initial_head" ] || return 1
  local current_head
  current_head="$(git -C "$workdir" rev-parse HEAD 2>/dev/null || echo "")"
  [ -n "$current_head" ] && [ "$current_head" != "$initial_head" ] && return 0
  ! git -C "$workdir" diff --quiet 2>/dev/null && return 0
  ! git -C "$workdir" diff --cached --quiet 2>/dev/null && return 0
  local untracked
  untracked="$(git -C "$workdir" ls-files --others --exclude-standard 2>/dev/null || true)"
  [ -n "$untracked" ] && return 0
  return 1
}

infer_task_base_branch() {
  local workdir="$1" branch="$2" fallback="$3"
  local message created_from

  # Git's branch reflog usually records "branch: Created from HEAD", which
  # does not preserve the actual source branch. Prefer explicit reset/create
  # entries when available, then inspect the HEAD reflog for the checkout
  # transition that created/entered this branch.
  while IFS= read -r message; do
    case "$message" in
      "branch: Created from "*) created_from="${message#branch: Created from }" ;;
      "branch: Reset to "*) created_from="${message#branch: Reset to }" ;;
      *) continue ;;
    esac
    case "$created_from" in
      HEAD|""|refs/remotes/origin/HEAD|refs/heads/"$branch"|"${branch}") continue ;;
    esac
    created_from="${created_from#refs/remotes/origin/}"
    created_from="${created_from#origin/}"
    created_from="${created_from#refs/heads/}"
    if git -C "$workdir" show-ref --verify --quiet "refs/remotes/origin/$created_from" || git -C "$workdir" show-ref --verify --quiet "refs/heads/$created_from"; then
      echo "$created_from"
      return 0
    fi
  done < <(git -C "$workdir" reflog show --format="%gs" "$branch" 2>/dev/null || true)

  while IFS= read -r message; do
    case "$message" in
      "checkout: moving from "*)
        created_from="${message#checkout: moving from }"
        case "$created_from" in
          *" to $branch") created_from="${created_from% to $branch}" ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    case "$created_from" in
      HEAD|""|refs/remotes/origin/HEAD|refs/heads/"$branch"|"${branch}") continue ;;
    esac
    created_from="${created_from#refs/remotes/origin/}"
    created_from="${created_from#origin/}"
    created_from="${created_from#refs/heads/}"
    if git -C "$workdir" show-ref --verify --quiet "refs/remotes/origin/$created_from" || git -C "$workdir" show-ref --verify --quiet "refs/heads/$created_from"; then
      echo "$created_from"
      return 0
    fi
  done < <(git -C "$workdir" reflog show --format="%gs" HEAD 2>/dev/null || true)

  echo "$fallback"
}

start_heartbeat() {
  ensure_claim_token_column || return 1
  local comment_id="$1"
  local worker_pid="${2:-$BASHPID}"
  local claim_token="${3:-}"
  local pid_file="$MANUL_DIR/task-${comment_id}.heartbeat.pid"

  local ownership_sql
  if [ -n "$claim_token" ]; then
    local safe_claim_token
    safe_claim_token="$(sql_escape "$claim_token")"
    ownership_sql="AND claimToken='$safe_claim_token'"
  else
    # Legacy rows created before claimToken used workerPid only.
    ownership_sql="AND claimToken IS NULL"
  fi
  (
    while true; do
      # Heartbeat belongs to this worker process and this exact claim.
      if ! kill -0 "$worker_pid" 2>/dev/null; then
        exit 0
      fi
      local changed
      changed="$(sqlite3 "$DB" "UPDATE processed_comments SET heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now', '+${LEASE_TIMEOUT} seconds') WHERE commentId='$(sql_escape "$comment_id")' AND status='running' AND workerPid=$worker_pid $ownership_sql; SELECT changes();" 2>/dev/null | tail -n 1)"
      if [ "${changed:-0}" -ne 1 ]; then
        exit 0
      fi
      sleep "$HEARTBEAT_INTERVAL"
    done
  ) &
  local heartbeat_pid=$!
  echo "$heartbeat_pid" > "$pid_file" 2>/dev/null || true
  HEARTBEAT_PIDS["$comment_id"]=$heartbeat_pid
  log "started heartbeat for task $comment_id (pid $heartbeat_pid)"
  lc_log "HEARTBEAT_START" "task=$comment_id pid=$heartbeat_pid interval=${HEARTBEAT_INTERVAL}s claim=${claim_token}"
}
stop_heartbeat() {
  local comment_id="$1"
  local pid_file="$MANUL_DIR/task-${comment_id}.heartbeat.pid"
  local pid="${HEARTBEAT_PIDS[$comment_id]:-}"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    unset HEARTBEAT_PIDS["$comment_id"]
  fi
  rm -f "$pid_file" 2>/dev/null || true
  log "stopped heartbeat for task $comment_id"
  lc_log "HEARTBEAT_STOP" "task=$comment_id"
}
# Refresh heartbeatAt in database to prevent watchdog timeout
refresh_heartbeat() {
  local comment_id="$1"
  if [ -n "${HEARTBEAT_PIDS[$comment_id]:-}" ]; then
    local worker_pid="${CURRENT_WORKER_PID:-$BASHPID}"
    local claim_token
    claim_token="$(sqlite3 "$DB" "SELECT claimToken FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' AND status='running' AND workerPid=$worker_pid LIMIT 1;" 2>/dev/null)"
    [ -n "$claim_token" ] || return 0
    local safe_claim_token
    safe_claim_token="$(sql_escape "$claim_token")"
    sqlite3 "$DB" "UPDATE processed_comments SET heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now', '+${LEASE_TIMEOUT} seconds') WHERE commentId='$(sql_escape "$comment_id")' AND status='running' AND workerPid=$worker_pid AND claimToken='$safe_claim_token';" 2>/dev/null || true
  fi
}

start() {
  configure_task_retention

  # Reclaim workspaces left BUSY by dead/stale workers before creating the pool.
  # This must happen before workspace_pool_init: a stale BUSY row otherwise
  # makes available_ws=0 and prevents the daemon from starting at all.
  local workspace_manager="$MANUL_DIR/workspace-manager.sh"
  if [ ! -f "$workspace_manager" ] || ! bash -n "$workspace_manager" 2>/dev/null; then
    log "ERROR: invalid workspace manager: $workspace_manager"
    return 1
  fi
  if ! source "$workspace_manager"; then
    log "ERROR: failed to source workspace manager: $workspace_manager"
    return 1
  fi
  if ! workspace_cleanup_stale 3600; then
    log "ERROR: workspace stale cleanup failed"
    return 1
  fi
  workspace_pool_init "$MAX_CONCURRENT_TASKS"

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

  # Check workspace availability
  local available_ws
  available_ws="$(workspace_available_count)"
  if [ "$available_ws" -lt "$MAX_CONCURRENT_TASKS" ]; then
    log "ERROR: insufficient workspaces for concurrency (have=$available_ws, need=$MAX_CONCURRENT_TASKS)"
    return 1
  fi

  # Lifecycle marker: this is an INTENTIONAL start. The .enabled marker is the
  # contract between intentional start/stop and the watchdog: the watchdog only
  # restarts the daemon when it is present, so crash recovery never re-enables
  # automation. Direct callers (aicode, the `manul` alias) reach this point
  # via start-manul-automation.sh, which also touches the marker; this touch is
  # the safety net for any path that invokes manul-daemon.sh start directly.
  touch "$MANUL_DIR/.enabled"

  # Atomically write PID file under flock to prevent concurrent start races
  exec 200>"$FLOCK_FILE"
  flock -n 200 || { echo "cannot acquire lock (another start in progress)" >&2; return 1; }

  # Fork the daemon to run in background.
  (
    # Child process: we are the daemon.
    # Write PID file under the lock (we already hold the lock via fd 200)
    echo "$BASHPID" >"$PID_FILE"

    # Spawn worker pool
    local i worker_pid
    local master_pid=$BASHPID
    declare -a WORKER_PIDS=()
for ((i = 0; i < MAX_CONCURRENT_TASKS; i++)); do
       # Use an absolute path so the worker survives even if the daemon's cwd
       # changes (nohup otherwise resolves a bare $0 against an unknown cwd).
       setsid nohup "$DAEMON_SCRIPT_ABS" loop --worker="$i" >>"$LOG" 2>&1 &
      worker_pid=$!
      echo "$worker_pid" >"$MANUL_DIR/worker-$i.pid"
      WORKER_PIDS+=("$worker_pid")
      log "spawned worker $i (pid=$worker_pid)"
    done

    flock -u 200
    log "$TASK_RETENTION_CONFIG_MESSAGE"
    lc_log "DAEMON_START" "pid=$master_pid interval=${INTERVAL}s workers=$MAX_CONCURRENT_TASKS"
    echo "manul daemon started (pid $master_pid, interval ${INTERVAL}s, workers=$MAX_CONCURRENT_TASKS)"

    # Signal handler: stop all workers on termination
    local stopping=0
    handle_stop() {
      if [ "$stopping" -eq 1 ]; then
        return
      fi
      stopping=1
      log "daemon received stop signal, terminating workers"
      for wp in "${WORKER_PIDS[@]}"; do
        kill "$wp" 2>/dev/null || true
      done
      wait 2>/dev/null || true
      rm -f "$PID_FILE"
      lc_log "DAEMON_STOP" "pid=$$"
      exit 0
    }
    trap handle_stop TERM INT

    # Stay alive as the long-lived daemon process, watching over workers
    while true; do
      # Wait for any worker to exit
      if [ ${#WORKER_PIDS[@]} -gt 0 ]; then
        wait -n "${WORKER_PIDS[@]}" 2>/dev/null || true
      else
        sleep 1
      fi
      # Check if we should stop
      if [ "$stopping" -eq 1 ]; then
        break
      fi
      # Restart any dead workers
      local new_pids=()
      for i in "${!WORKER_PIDS[@]}"; do
if ! kill -0 "${WORKER_PIDS[$i]}" 2>/dev/null; then
           log "worker $i died (pid=${WORKER_PIDS[$i]}), restarting"
           setsid nohup "$DAEMON_SCRIPT_ABS" loop --worker="$i" >>"$LOG" 2>&1 &
          worker_pid=$!
          echo "$worker_pid" >"$MANUL_DIR/worker-$i.pid"
          new_pids+=("$worker_pid")
        else
          new_pids+=("${WORKER_PIDS[$i]}")
        fi
      done
      WORKER_PIDS=("${new_pids[@]}")
    done
  ) &
  local daemon_pid=$!

  # Parent: we release the lock and return.
  flock -u 200
  return 0
}
stop() {
  # Lifecycle marker: this is an INTENTIONAL stop. Remove .enabled so the
  # watchdog stops trying to restart the daemon (crash recovery never
  # re-enables automation). Done before the early return so a "not running"
  # answer still clears a stale marker left by a previous crash.
  rm -f "$MANUL_DIR/.enabled"

  if [ ! -f "$PID_FILE" ]; then
    echo "not running"
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  # Kill all worker processes
  for pf in "$MANUL_DIR"/worker-*.pid; do
    [ -f "$pf" ] || continue
    local wpid
    wpid="$(cat "$pf" 2>/dev/null)"
    [ -n "$wpid" ] && kill "$wpid" 2>/dev/null || true
    rm -f "$pf"
  done
  kill "$pid" 2>/dev/null
  wait 2>/dev/null || true
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


# Return the number of queued tasks that are eligible to run now.
# SQLite is the authoritative scheduler state; poll.sh only provides a wake-up hint.
eligible_queued_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued' AND (attempts=0 OR nextAttemptAt <= datetime('now'));" 2>/dev/null || echo 0
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}
# Remove terminal task rows older than the configured history retention.
# Only processed_comments task data is removed; conversation_messages keeps
# message IDs so an old GitHub trigger cannot be rediscovered and requeued.
cleanup_expired_tasks() {
  [ -f "$DB" ] || return 0

  local deleted
  deleted="$(sqlite3 "$DB" "
    DELETE FROM processed_comments
    WHERE status IN ('completed', 'failed', 'stale')
      AND COALESCE(processedAt, createdAt) < datetime('now', '-${TASK_HISTORY_RETENTION_DAYS} days');
    SELECT changes();
  " 2>>"$LOG" | tail -n 1)"

  if [[ "$deleted" =~ ^[0-9]+$ ]] && [ "$deleted" -gt 0 ]; then
    log "task retention cleanup: removed $deleted terminal task(s) older than ${TASK_HISTORY_RETENTION_DAYS} days"
  elif [ -n "$deleted" ] && ! [[ "$deleted" =~ ^[0-9]+$ ]]; then
    log "WARN: task retention cleanup returned unexpected result: $deleted"
  fi
}


# Ensure the workspace pool is healthy for long-lived daemons.
# The watchdog may remove stale idle workspaces while this daemon remains alive;
# replenish the pool before every dispatch cycle instead of waiting for start().
ensure_workspace_pool() {
  local workspace_manager="$MANUL_DIR/workspace-manager.sh"
  if [ ! -f "$workspace_manager" ]; then
    log "ERROR: workspace manager not found: $workspace_manager"
    return 1
  fi

  # Source here as well as in loop() so direct run-once invocations get the
  # same workspace-pool lifecycle guarantees as the long-running daemon.
  if ! source "$workspace_manager"; then
    log "ERROR: failed to source workspace manager: $workspace_manager"
    return 1
  fi
  if ! workspace_cleanup_stale 3600; then
    log "ERROR: workspace stale cleanup failed"
    return 1
  fi
  if ! workspace_pool_init "$MAX_CONCURRENT_TASKS"; then
    log "ERROR: workspace pool initialization failed (size=$MAX_CONCURRENT_TASKS)"
    return 1
  fi

  local total
  total="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status IN ('IDLE','BUSY');" 2>/dev/null || echo 0)"
  if [ "${total:-0}" -lt "$MAX_CONCURRENT_TASKS" ]; then
    log "ERROR: workspace pool below requested capacity after reconciliation (have=${total:-0}, need=$MAX_CONCURRENT_TASKS)"
    return 1
  fi
  return 0
}

# Ensure nextAttemptAt column exists in processed_comments
# Idempotent: safe to call multiple times, works on fresh and existing DBs
# Uses BEGIN IMMEDIATE to prevent race when multiple workers start concurrently
ensure_nextattemptat_column() {
  local has_column
  has_column="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -c '|nextAttemptAt|' || echo "0")"
  if [ "$has_column" -eq 0 ]; then
    log "migration: adding nextAttemptAt column to processed_comments"
    # Use BEGIN IMMEDIATE to serialize concurrent migration attempts
    sqlite3 "$DB" "BEGIN IMMEDIATE; ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT; UPDATE processed_comments SET nextAttemptAt = datetime('now', '+60 seconds') WHERE status='queued' AND attempts > 0 AND nextAttemptAt IS NULL; COMMIT;" 2>>"$LOG" || {
      log "ERROR: failed to add nextAttemptAt column"
      return 1
    }
    log "migration: nextAttemptAt column added and initialized"
  fi
  return 0
}

# Ensure each task claim has a unique ownership token. workerPid identifies a long-lived worker loop, not one specific task execution.
ensure_claim_token_column() {
  if sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|claimToken|'; then
    return 0
  fi
  log "migration: adding claimToken column to processed_comments"
  local alter_err
  alter_err="$(sqlite3 "$DB" "BEGIN IMMEDIATE; ALTER TABLE processed_comments ADD COLUMN claimToken TEXT; COMMIT;" 2>&1)" || {
    # Another worker may have won the migration race.
    if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|claimToken|'; then
      log "ERROR: failed to add claimToken column: $alter_err"
      return 1
    fi
  }
  log "migration: claimToken column added or already present"
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

  # Use temp files to avoid pipe deadlock (gh api --paginate can block indefinitely)
  local tmpdir
  tmpdir="$(mktemp -d)"

   local comments_file="$tmpdir/comments.json"
   local bodies_file="$tmpdir/bodies.txt"
   local reply_bodies_file="$tmpdir/reply_bodies.txt"
   local result_count=0
  local reply_count=0

  # Query all Manul comments; filter for author and marker
  # Apply timeout directly to gh api to prevent hangs and avoid pipe deadlock
  timeout "$GH_API_TIMEOUT" gh api "repos/$repo/issues/$url_issue_num/comments" \
    --paginate \
    --jq '.[] | select(.in_reply_to_id == null) | .body // "" | gsub("\n"; "\\n")' \
    2>>"$LOG" > "$bodies_file" || {
      local api_rc=$?
      if [ "$api_rc" -eq 124 ]; then
        log "ERROR: verify_result_comment: gh api timed out after ${GH_API_TIMEOUT}s — fail-closed"
        lc_log "API_TIMEOUT" "task=$comment_id repo=$repo issue=$url_issue_num timeout=${GH_API_TIMEOUT}s"
      else
        log "ERROR: verify_result_comment: gh api failed with exit code $api_rc — fail-closed"
        lc_log "API_FAILURE" "task=$comment_id repo=$repo issue=$url_issue_num exit_code=$api_rc"
      fi
      return 1
    }

  while IFS= read -r body; do
    # Exclude lifecycle comments (daemon posts these with same author/signature)
    # Reject lifecycle comments based on structural prefix (starts with emoji)
    # A valid result may contain these emojis in its body, but lifecycle comments
    # always start with them immediately (e.g., "✅ Manul completed...")
    if [[ "$body" == '🔄'* ]] || [[ "$body" == '✅'* ]] || [[ "$body" == '❌'* ]] || [[ "$body" == '⚠️'* ]]; then
      continue
    fi
    # Require exact deterministic marker
    if [[ "$body" == *"$marker"* ]]; then
      result_count=$((result_count + 1))
    fi
  done < "$bodies_file"

  if [ "$result_count" -gt 1 ]; then
    log "ERROR: verify_result_comment: multiple result comments with same marker for task $comment_id attempt $attempt on $repo#$url_issue_num — reject duplicates"
    lc_log "DUPLICATE_RESULT_COMMENT" "task=$comment_id repo=$repo issue=$url_issue_num attempt=$attempt count=$result_count"
    return 1
  fi

  if [ "$result_count" -gt 0 ]; then
    log "verify_result_comment: found result comment for task $comment_id attempt $attempt on $repo#$url_issue_num"
    return 0
  fi

  # Also check for reply comments (in_reply_to matches a known Manul lifecycle comment)
  # Apply timeout directly to gh api to prevent hangs
  timeout "$GH_API_TIMEOUT" gh api "repos/$repo/issues/$url_issue_num/comments" \
    --paginate \
    --jq '.[] | select(.in_reply_to_id != null) | .body // "" | gsub("\n"; "\\n")' \
    2>>"$LOG" > "$reply_bodies_file" || {
      local api_rc=$?
      if [ "$api_rc" -eq 124 ]; then
        log "ERROR: verify_result_comment: gh api (reply) timed out after ${GH_API_TIMEOUT}s — fail-closed"
        lc_log "API_TIMEOUT" "task=$comment_id repo=$repo issue=$url_issue_num reply_timeout=${GH_API_TIMEOUT}s"
      else
        log "ERROR: verify_result_comment: gh api (reply) failed with exit code $api_rc — fail-closed"
        lc_log "API_FAILURE" "task=$comment_id repo=$repo issue=$url_issue_num reply_exit_code=$api_rc"
      fi
      return 1
    }

  while IFS= read -r body; do
    # Reject lifecycle comments based on structural prefix (starts with emoji)
    if [[ "$body" == '🔄'* ]] || [[ "$body" == '✅'* ]] || [[ "$body" == '❌'* ]] || [[ "$body" == '⚠️'* ]]; then
      continue
    fi
    # Require exact deterministic marker
    if [[ "$body" == *"$marker"* ]]; then
      reply_count=$((reply_count + 1))
    fi
  done < "$reply_bodies_file"

  if [ "$reply_count" -gt 1 ]; then
    log "ERROR: verify_result_comment: multiple reply comments with same marker for task $comment_id attempt $attempt on $repo#$url_issue_num — reject duplicates"
    lc_log "DUPLICATE_RESULT_COMMENT" "task=$comment_id repo=$repo issue=$url_issue_num attempt=$attempt reply_count=$reply_count"
    return 1
  fi

  if [ "$reply_count" -gt 0 ]; then
    log "verify_result_comment: found reply result comment for task $comment_id attempt $attempt on $repo#$url_issue_num"
    return 0
  fi

  log "ERROR: verify_result_comment: no result comment with marker '$marker' found for task $comment_id attempt $attempt on $repo#$url_issue_num"
  lc_log "MISSING_RESULT_COMMENT" "task=$comment_id repo=$repo issue=$url_issue_num attempt=$attempt"
  return 1
}



# Check whether a concrete GitHub PR exists for the given branch against base.
# Returns 0 if a real PR exists, 1 otherwise.
# A /pull/new/... or /compare/... URL returned by the agent is NOT a concrete PR.
pr_check_existing() {
  local repo="$1" branch="$2" expected_base="${3:-}"
  local pr_json api_rc
  pr_json="$(timeout "$GH_API_TIMEOUT" gh pr list --repo "$repo" --state all --head "$branch" --json number,url,state,baseRefName,headRefName --limit 10 2>>"$LOG")"
  api_rc=$?
  if [ "$api_rc" -ne 0 ]; then
    if [ "$api_rc" -eq 124 ]; then
      log "ERROR: pr_check_existing: gh pr list timed out after ${GH_API_TIMEOUT}s"
      lc_log "PR_VERIFY_ERROR" "repo=$repo reason=api_timeout timeout=${GH_API_TIMEOUT}s"
    else
      log "ERROR: pr_check_existing: gh pr list failed with exit code $api_rc"
      lc_log "PR_VERIFY_ERROR" "repo=$repo reason=api_failure exit_code=$api_rc"
    fi
    return 1
  fi
  if [ -n "$expected_base" ]; then
    if printf '%s' "$pr_json" | jq -e --arg expected "$expected_base" 'any(.[]; .baseRefName == $expected)' >/dev/null 2>&1; then return 0; fi
    log "WARN: pr_check_existing: PR found for $repo/$branch but none targets expected base '$expected_base'"
    return 1
  fi
  jq -e 'length > 0' <<<"$pr_json" >/dev/null 2>&1
}

# Auto-create a GitHub PR for the given branch against the default branch.
# Used when autoCreatePr is enabled and the agent pushed its branch but did not
# itself open a PR (e.g. it only returned a /compare/... URL).
# Returns 0 on success, 1 on failure.
pr_auto_create() {
  local repo="$1" branch="$2" base_branch="$3" comment_id="$4" workdir="$5"
  local title body pr_url api_rc remote

  # Best-effort: ensure the branch is present on the remote before creating a PR.
  remote="$(git -C "$workdir" remote 2>/dev/null | head -1 || echo "")"
  if [ -n "$remote" ]; then
    if ! git -C "$workdir" ls-remote --heads "$remote" "$branch" 2>/dev/null | grep -q "$branch"; then
      log "pr_auto_create: pushing branch $branch to remote $remote before PR creation"
      if ! git -C "$workdir" push "$remote" "$branch" 2>>"$LOG"; then
        log "WARN: pr_auto_create: failed to push branch $branch to $remote (continuing to gh pr create)"
      fi
    fi
  fi

  # Derive a sensible PR title from the latest commit, falling back to the branch name.
  title="$(git -C "$workdir" log -1 --pretty=%s 2>/dev/null || echo "$branch")"
  title="${title:0:120}"
  [ -n "$title" ] || title="$branch"

  body="Automatically created by Manul for task $comment_id."

  local pr_create_output
  pr_create_output="$(timeout "$GH_API_TIMEOUT" gh pr create --repo "$repo" --base "$base_branch" --head "$branch" --title "$title" --body "$body" 2>>"$LOG")"
  api_rc=$?
  if [ "$api_rc" -ne 0 ]; then
    if [ "$api_rc" -eq 124 ]; then
      log "ERROR: pr_auto_create: gh pr create timed out after ${GH_API_TIMEOUT}s for branch $branch"
      lc_log "PR_CREATE_ERROR" "task=$comment_id repo=$repo branch=$branch reason=timeout timeout=${GH_API_TIMEOUT}s"
    else
      log "ERROR: pr_auto_create: gh pr create failed with exit code $api_rc for branch $branch"
      lc_log "PR_CREATE_ERROR" "task=$comment_id repo=$repo branch=$branch reason=exit_code exit_code=$api_rc"
    fi
    return 1
  fi

  pr_url="$(printf '%s' "$pr_create_output" | tr -d '[:space:]')"
  # gh pr create returning 0 is not sufficient: the output can be malformed,
  # stale, or a create/compare URL. Re-query GitHub and require a real PR with
  # the expected head and base before treating creation as successful.
  if ! pr_check_existing "$repo" "$branch" "$base_branch"; then
    log "ERROR: pr_auto_create: gh pr create returned success but GitHub has no verified PR for $branch -> $pr_url"
    lc_log "PR_CREATE_ERROR" "task=$comment_id repo=$repo branch=$branch base=$base_branch reason=post_create_verification_failed"
    return 1
  fi
  log "pr_auto_create: verified created PR for branch $branch against $base_branch -> $pr_url"
  lc_log "PR_CREATE_SUCCESS" "task=$comment_id repo=$repo branch=$branch base=$base_branch url=$pr_url"
  return 0
}

# Verify that a repository-change task has a real PR against the branch that
# the agent actually based its task branch on. A /pull/new/... or /compare/...
# URL is NOT a concrete PR — only a real PR (verified via the GitHub API) counts.
#
# autoCreatePr controls ONLY whether the daemon creates the PR itself when the
# agent pushed its branch but did not open a PR (e.g. it returned a
# /compare/... URL instead of a PR). It must NOT mask the requirement: when no
# PR exists and autoCreatePr is false, the task still fails.
verify_required_pr() {
  local repo="$1" comment_id="$2" workdir="$3" initial_base_branch="$4"
  local auto_create_pr
  auto_create_pr="$(jq -r '.autoCreatePr // false' "$CONFIG" 2>/dev/null || echo false)"
  local safe_comment_id="$(sql_escape "$comment_id")"
  local action
  action="$(sqlite3 "$DB" "SELECT action FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null)"
  # Legacy tasks may have a NULL/empty action because the action column was
  # introduced after the task was queued. Standalone issue/comment tasks are
  # implementation tasks by default; only an explicit non-IMPLEMENT action
  # (e.g. REVIEW_FIX) opts out of standalone PR verification.
  action="${action:-IMPLEMENT}"
  [ "$action" = "IMPLEMENT" ] || return 0
  local comment_url
  comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null)"
  [[ "$comment_url" == *"/pull/"* ]] && return 0
  local branch
  branch="$(git -C "$workdir" symbolic-ref --short HEAD 2>/dev/null)"
  if [ -z "$branch" ] || [ "$branch" = "$initial_base_branch" ]; then
    log "ERROR: verify_required_pr: invalid task branch for $comment_id (branch=$branch initial_base=$initial_base_branch)"
    lc_log "PR_VERIFY_ERROR" "task=$comment_id repo=$repo reason=invalid_task_branch branch=$branch base=$initial_base_branch"
    return 1
  fi
  local expected_base
  expected_base="$(infer_task_base_branch "$workdir" "$branch" "$initial_base_branch")"
  log "verify_required_pr: task $comment_id branch=$branch expected_base=$expected_base"
  if pr_check_existing "$repo" "$branch" "$expected_base"; then
    log "verify_required_pr: found PR for task $comment_id branch=$branch base=$expected_base"
    return 0
  fi
  if [ "$auto_create_pr" = "true" ]; then
    log "verify_required_pr: no PR for branch $branch; auto-creating PR against $expected_base"
    lc_log "PR_CREATE_ATTEMPT" "task=$comment_id repo=$repo branch=$branch base=$expected_base"
    if pr_auto_create "$repo" "$branch" "$expected_base" "$comment_id" "$workdir"; then
      log "verify_required_pr: PR auto-created for task $comment_id branch=$branch base=$expected_base"
      return 0
    fi
  fi
  log "ERROR: verify_required_pr: no PR found for branch $branch against expected base $expected_base"
  lc_log "MISSING_PR" "task=$comment_id repo=$repo branch=$branch base=$expected_base"
  return 1
}

# Verify that the agent's result comment contains the exact canonical URL
# of the real PR belonging to this task branch. This prevents an issue URL,
# an issue number masquerading as a PR number, /compare links, or stale PR links
# from being reported as the task result.
verify_result_comment_pr_url() {
  local repo="$1" issue_num="$2" comment_id="$3" safe_comment_id="$4" attempt="$5" workdir="$6" expected_base="$7"
  local branch="$8"

  local pr_json
  pr_json="$(timeout "$GH_API_TIMEOUT" gh pr list --repo "$repo" --state all --head "$branch" --json number,url,baseRefName,headRefName --limit 10 2>>"$LOG")" || {
    log "ERROR: verify_result_comment_pr_url: failed to query PR for $repo/$branch"
    lc_log "PR_RESULT_LINK_VERIFY_ERROR" "task=$comment_id repo=$repo branch=$branch reason=api_failure"
    return 1
  }

  local pr_url
  pr_url="$(printf '%s' "$pr_json" | jq -r --arg base "$expected_base" --arg head "$branch" 'map(select(.baseRefName == $base and .headRefName == $head and (.state == null or .state != "closed"))) | .[0].url // empty' 2>/dev/null)"
  # The PR may be closed; for the task result we still accept the concrete PR
  # that belongs to this branch/base, so retry without the state assumption.
  if [ -z "$pr_url" ]; then
    pr_url="$(printf '%s' "$pr_json" | jq -r --arg base "$expected_base" --arg head "$branch" 'map(select(.baseRefName == $base and .headRefName == $head)) | .[0].url // empty' 2>/dev/null)"
  fi
  if [ -z "$pr_url" ]; then
    log "ERROR: verify_result_comment_pr_url: no verified PR URL for $repo/$branch base=$expected_base"
    lc_log "PR_RESULT_LINK_VERIFY_ERROR" "task=$comment_id repo=$repo branch=$branch base=$expected_base reason=no_verified_pr"
    return 1
  fi

  local comment_url
  comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' LIMIT 1;" 2>/dev/null)"
  local target_issue
  target_issue="$(printf '%s' "$comment_url" | grep -oE '(issues|pull)/[0-9]+' | grep -oE '[0-9]+' || echo "$issue_num")"

  local bodies
  bodies="$(timeout "$GH_API_TIMEOUT" gh api "repos/$repo/issues/$target_issue/comments" --paginate --jq '.[].body // ""' 2>>"$LOG")" || {
    log "ERROR: verify_result_comment_pr_url: failed to fetch result comments"
    lc_log "PR_RESULT_LINK_VERIFY_ERROR" "task=$comment_id repo=$repo reason=comment_api_failure"
    return 1
  }

  if printf '%s\n' "$bodies" | grep -Fq -- "$pr_url"; then
    log "verify_result_comment_pr_url: exact PR URL present for task $comment_id -> $pr_url"
    return 0
  fi

  # Review-thread replies are returned through the same issue comments endpoint
  # but can be useful to check explicitly for consistency with routing.
  log "ERROR: verify_result_comment_pr_url: result comment does not contain canonical PR URL $pr_url"
  lc_log "PR_RESULT_LINK_MISSING" "task=$comment_id repo=$repo branch=$branch base=$expected_base expected_url=$pr_url"
  return 1
}

# ── Source revalidation ────────────────────────────────────────────────────────
# Pre-flight check before dispatching a claimed task.  Ensures the GitHub source
# (issue, PR, or review thread) still exists and is in an active state.
# Returns: 0=fresh (proceed), 1=stale (terminal), 2=transient (requeue).

# Detect the source kind from a comment_id prefix.
# Prefixes are authoritative:
#   issue:     -> issue comment
#   issuebody: -> issue/PR state
#   ci_fix:    -> PR state
#   review:    -> PR review thread/comment
detect_source_kind() {
  local comment_id="$1"
  case "$comment_id" in
    review:*)    echo "pr_review_comment" ;;
    issuebody:*) echo "issue_state" ;;
    ci_fix:*)    echo "pr_state" ;;
    issue:*)     echo "issue_comment" ;;
    *)           echo "issue_comment" ;;
  esac
}

# Revalidate a single source. Returns:
#   0 = fresh
#   1 = stale (terminal)
#   2 = transient (requeue)
# The issue/PR number is passed separately because review:<id> contains only
# the review comment database ID.
revalidate_source() {
  local comment_id="$1"
  local repo="$2"
  local issue_num="${3:-}"
  local source_url="${4:-}"
  local kind
  kind="$(detect_source_kind "$comment_id")"
  case "$kind" in
    issue_comment)      revalidate_issue_comment "$comment_id" "$repo" ;;
    issue_state)        revalidate_issue_state "$comment_id" "$repo" "$source_url" ;;
    pr_state)           revalidate_pr_state "$comment_id" "$repo" ;;
    pr_review_comment)  revalidate_pr_review_comment "$comment_id" "$repo" "$issue_num" ;;
    *)                  return 2 ;;
  esac
}

# ── issue_comment ─────────────────────────────────────────────────────────────
# Matched by prefix issue:<id>. Verifies the comment still exists on GitHub.
revalidate_issue_comment() {
  local comment_id="$1" repo="$2"
  local num="${comment_id#issue:}"
  local owner name
  IFS='/' read -r owner name _ <<<"$repo"

  local resp rc
  resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$owner/$name/issues/comments/$num" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then return 2; fi
    if printf '%s' "$resp" | jq -e -r '.message == "Not Found"' >/dev/null 2>&1; then
      log "revalidate_source: issue comment $num not found on $repo — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_comment reason=not_found"
      return 1
    fi
    log "revalidate_source: issue comment API error for $comment_id (rc=$rc)"
    return 2
  fi

  local returned_id
  returned_id="$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)"
  if [ -n "$returned_id" ]; then
    log "revalidate_source: issue comment $num still exists on $repo — fresh"
    return 0
  fi
  log "revalidate_source: issue comment $num returned no id — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_comment reason=missing_id"
  return 1
}

# ── issue_state ───────────────────────────────────────────────────────────────
revalidate_issue_state() {
  local comment_id="$1" repo="$2" source_url="${3:-}"
  local num="${comment_id#issuebody:}"

  # issuebody task IDs are GitHub API object IDs, while /issues/<N> expects
  # the human-facing issue number. The stored issue URL is authoritative for
  # legacy queue rows created with the wrong numeric identifier.
  if [[ "$source_url" =~ /issues/([0-9]+)(/|#|$) ]]; then
    local source_num="${BASH_REMATCH[1]}"
    if [ "$source_num" != "$num" ]; then
      log "revalidate_source: correcting issuebody source id $num to issue number $source_num from $source_url"
      num="$source_num"
    fi
  fi

  local owner name
  IFS='/' read -r owner name _ <<<"$repo"

  local resp rc
  resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$owner/$name/issues/$num" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then return 2; fi
    if printf '%s' "$resp" | jq -e -r '.message == "Not Found"' >/dev/null 2>&1; then
      log "revalidate_source: issue $num not found on $repo — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_state reason=not_found"
      return 1
    fi
    log "revalidate_source: issue state API error for $comment_id (rc=$rc)"
    return 2
  fi
  local state
  state="$(printf '%s' "$resp" | jq -r '.state // empty' 2>/dev/null || true)"
  if [ "$state" = "open" ]; then
    log "revalidate_source: issue $num is still open on $repo — fresh"
    return 0
  fi
  log "revalidate_source: issue $num is ${state:-unknown} on $repo — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_state reason=closed state=${state:-unknown}"
  return 1
}

# ── pr_state ──────────────────────────────────────────────────────────────────
# Matched by prefix ci_fix:<repo>:<pr_num>:<run_id>. OPEN only.
revalidate_pr_state() {
  local comment_id="$1" repo="$2"
  local pr_num
  case "$comment_id" in
    ci_fix:*) pr_num="$(printf '%s' "$comment_id" | awk -F: '{print $3}')" ;;
    *) return 2 ;;
  esac
  [[ "$pr_num" =~ ^[0-9]+$ ]] || return 2

  local owner name
  IFS='/' read -r owner name _ <<<"$repo"
  local resp rc
  resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$owner/$name/pulls/$pr_num" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then return 2; fi
    if printf '%s' "$resp" | jq -e -r '.message == "Not Found"' >/dev/null 2>&1; then
      log "revalidate_source: PR $pr_num not found on $repo — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_state reason=not_found"
      return 1
    fi
    log "revalidate_source: PR state API error for $comment_id (rc=$rc)"
    return 2
  fi
  local state
  state="$(printf '%s' "$resp" | jq -r '.state // empty' 2>/dev/null || true)"
  if [ "$state" = "open" ]; then
    log "revalidate_source: PR $pr_num is open on $repo — fresh"
    return 0
  fi
  log "revalidate_source: PR $pr_num is ${state:-unknown} on $repo — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_state reason=pr_${state:-unknown}"
  return 1
}

# ── pr_review_comment ─────────────────────────────────────────────────────────
# review:<id> uses issueNumber as the PR number. Verifies PR OPEN, thread
# unresolved, and paginates reviewThreads until found/exhausted.
revalidate_pr_review_comment() {
  local comment_id="$1" repo="$2" pr_num="$3"
  local tid="${comment_id#review:}"
  [[ "$tid" =~ ^[0-9]+$ ]] || return 2
  [[ "$pr_num" =~ ^[0-9]+$ ]] || return 2

  local owner name
  IFS='/' read -r owner name _ <<<"$repo"
  local tmp_cursor="" has_more=true
  local q_base='query($o:String!,$n:String!,$num:Int!,$c:String){repository(owner:$o,name:$n){pullRequest(number:$num){state reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor}nodes{isResolved comments(first:100){nodes{databaseId}}}}}}}'
  local q_no_cursor='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){pullRequest(number:$num){state reviewThreads(first:100){pageInfo{hasNextPage endCursor}nodes{isResolved comments(first:100){nodes{databaseId}}}}}}}'

  while $has_more; do
    local resp rc
    if [ -n "$tmp_cursor" ]; then
      resp="$(timeout "$GH_API_TIMEOUT" gh api graphql --field query="$q_base" --field o="$owner" --field n="$name" --field num="$pr_num" --field c="$tmp_cursor" 2>/dev/null)" && rc=0 || rc=$?
    else
      resp="$(timeout "$GH_API_TIMEOUT" gh api graphql --field query="$q_no_cursor" --field o="$owner" --field n="$name" --field num="$pr_num" 2>/dev/null)" && rc=0 || rc=$?
    fi
    if [ "$rc" -eq 124 ]; then
      log "revalidate_source: review GraphQL timeout for $comment_id"
      return 2
    fi
    if [ "$rc" -ne 0 ]; then
      log "revalidate_source: review GraphQL error for $comment_id (rc=$rc)"
      return 2
    fi

    local pr_null
    pr_null="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest == null' 2>/dev/null || true)"
    if [ "$pr_null" = "true" ]; then
      log "revalidate_source: PR $pr_num not found for review $comment_id — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=pr_not_found"
      return 1
    fi

    local pr_state
    pr_state="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.state // empty' 2>/dev/null || true)"
    if [ "$pr_state" != "OPEN" ]; then
      log "revalidate_source: PR $pr_num is ${pr_state:-unknown} on $repo — stale for review task"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=pr_${pr_state:-unknown}"
      return 1
    fi

    local thread_info
    thread_info="$(printf '%s' "$resp" | jq -r --argjson tid "$tid" '.data.repository.pullRequest.reviewThreads.nodes[]? | select((.comments.nodes // []) | map(.databaseId) | index($tid) != null) | "\(.isResolved)"' 2>/dev/null || true)"
    if [ -n "$thread_info" ]; then
      if [ "$(printf '%s' "$thread_info" | head -1)" = "true" ]; then
        log "revalidate_source: review thread $tid is resolved on $repo — stale"
        lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=resolved"
        return 1
      fi
      log "revalidate_source: review thread $tid is unresolved on $repo — fresh"
      return 0
    fi

    local has_next next_cursor
    has_next="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null || echo false)"
    next_cursor="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' 2>/dev/null || true)"
    if [ "$has_next" != "true" ] || [ -z "$next_cursor" ]; then
      has_more=false
    else
      tmp_cursor="$next_cursor"
    fi
  done

  log "revalidate_source: review thread $tid not found after pagination on $repo — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=thread_not_found"
  return 1
}

# Mark a running task as blocked on explicit user input.
# This is not a failure and is not retryable. A later /manul continue resumes
# this exact task.
mark_task_blocked_user() {
  local comment_id="$1" safe_comment_id="$2" claim_token="$3"
  local safe_claim_token
  safe_claim_token="$(sql_escape "$claim_token")"
  local result changes
  result="$(sqlite3 "$DB" "UPDATE processed_comments SET status='blocked_user', processedAt=datetime('now'), heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token'; SELECT changes();" 2>/dev/null)"
  changes="$(printf '%s\n' "$result" | tail -1)"
  if [ "$changes" = "1" ]; then
    log "mark_task_blocked_user: task $comment_id is waiting for user input"
    lc_log "TASK_NEEDS_USER" "task=$comment_id"
    return 0
  fi
  log "ERROR: mark_task_blocked_user did not update task $comment_id (changes=$changes)"
  lc_log "TASK_ERROR" "task=$comment_id reason=mark_blocked_failed"
  return 1
}

post_task_needs_user_comment() {
  local repo="$1" issue="$2" comment_id="$3" question="$4" reply_to="${5:-}"
  local task_attempt conversation_id
  task_attempt="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' LIMIT 1;" 2>/dev/null || echo "1")"
  conversation_id="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' LIMIT 1;" 2>/dev/null || echo "")"

  local event_json
  event_json="$(jq -n \
    --arg taskId "$comment_id" \
    --arg conversationId "$conversation_id" \
    --arg question "$question" \
    --argjson attempt "$task_attempt" \
    '{type:"TASK_NEEDS_USER", timestamp:(now | strftime("%Y-%m-%dT%H:%M:%SZ")), data:{taskId:$taskId,conversationId:$conversationId,attempt:$attempt,question:$question}}' | jq -c .)"

  local body
  body="<!-- manul:event $event_json -->

❓ **Manul needs your input to continue**

$question

Reply with:

\`/manul continue <your answer>\`

The answer will resume this same task and conversation.

— manul 🐈"

  post_github_comment "$repo" "$issue" "$body" "$reply_to"
}
# Mark a running task as stale (terminal).
mark_task_stale() {
  local comment_id="$1" safe_comment_id="$2" claim_token="$3"
  local safe_claim_token
  safe_claim_token="$(sql_escape "$claim_token")"
  local result changes
  result="$(sqlite3 "$DB" "UPDATE processed_comments SET status='stale', processedAt=datetime('now'), heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token'; SELECT changes();" 2>/dev/null)"
  changes="$(printf '%s\n' "$result" | tail -1)"
  if [ "$changes" = "1" ]; then
    log "mark_task_stale: task $comment_id marked stale"
    lc_log "TASK_STALE" "task=$comment_id"
    return 0
  fi
  log "ERROR: mark_task_stale did not update task $comment_id (changes=$changes)"
  lc_log "TASK_ERROR" "task=$comment_id reason=mark_stale_failed"
  return 1
}

# Requeue a running task for later retry.
requeue_task() {
  local comment_id="$1" safe_comment_id="$2" claim_token="$3"
  local safe_claim_token
  safe_claim_token="$(sql_escape "$claim_token")"
  local result changes
  result="$(sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now','+${RETRY_DELAY_SECONDS} seconds') WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token'; SELECT changes();" 2>/dev/null)"
  changes="$(printf '%s\n' "$result" | tail -1)"
  if [ "$changes" = "1" ]; then
    log "requeue_task: task $comment_id requeued"
    lc_log "TASK_REQUEUED" "task=$comment_id reason=revalidation_transient"
    return 0
  fi
  log "ERROR: requeue_task did not update task $comment_id (changes=$changes)"
  lc_log "TASK_ERROR" "task=$comment_id reason=requeue_failed"
  return 1
}
# Evaluate task completion decision based on wrapper output and verification
# Sets: COMPLETION_SUCCESS, FAIL_REASON, FINAL_COMMENT
# Args: repo issue_num comment_id safe_comment_id attempt rc stdout_file db [repo_dir] [workdir] [claim_token] [initial_head] [initial_branch] [initial_base_branch]
evaluate_task_completion() {
  local REPO="$1"
  local ISSUE_NUM="$2"
  local COMMENT_ID="$3"
  local safe_comment_id="$4"
  local current_attempt="$5"
  local rc="$6"
  local STDOUT_FILE="$7"
  local DB="$8"
  local REPO_DIR="${9:-}"
  local WORKDIR="${10:-$REPO_DIR}"
  local CLAIM_TOKEN="${11:-}"
  local INITIAL_HEAD="${12:-}"
  local INITIAL_BRANCH="${13:-}"
  local INITIAL_BASE_BRANCH="${14:-${INITIAL_BRANCH:-$DEFAULT_BRANCH}}"
  
  COMPLETION_SUCCESS="false"
  FAIL_REASON=""
  FINAL_COMMENT=""
  NEEDS_USER_INPUT="false"
  USER_QUESTION=""
  
  local SUCCESS="false"

  # A user-input request is a deliberate pause, not task failure.
  # Detect the structured block before any success/failure verification.
  if [ -f "$STDOUT_FILE" ] && grep -q "^TASK_NEEDS_USER_BEGIN$" "$STDOUT_FILE"; then
    local question
    question="$(awk '/^TASK_NEEDS_USER_BEGIN$/{inside=1; next} /^TASK_NEEDS_USER_END$/{inside=0; exit} inside{print}' "$STDOUT_FILE" 2>/dev/null || true)"
    if [ -n "$question" ]; then
      NEEDS_USER_INPUT="true"
      USER_QUESTION="$question"
      log "dispatch: task $COMMENT_ID requested user input"
      lc_log "TASK_NEEDS_USER" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM"
      return 0
    fi
    log "WARN: task $COMMENT_ID emitted TASK_NEEDS_USER_BEGIN without a question block; treating as normal failure"
  fi
  
  # 7. Determine success using BOTH exit status AND explicit completion marker
  if [ "$rc" -eq 0 ]; then
    if [ -f "$STDOUT_FILE" ] && grep -qE 'TASK_DONE|TASK_COMPLETED' "$STDOUT_FILE"; then
      SUCCESS="true"
    elif [ -f "$STDOUT_FILE" ] && grep -qE 'TASK_FAILED:' "$STDOUT_FILE"; then
      FAIL_REASON="$(grep -E 'TASK_FAILED:' "$STDOUT_FILE" | head -1 | sed -E 's/.*TASK_FAILED: //')"
    fi
  fi
  
  # 7.1 Verify agent posted result comment for THIS exact task/attempt before accepting TASK_DONE
  if [ "$SUCCESS" = "true" ]; then
    if ! verify_result_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt"; then
      log "dispatch: task $COMMENT_ID attempt $current_attempt has no result comment — marking as failed"
      lc_log "MISSING_RESULT_COMMENT" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempt=$current_attempt"
      SUCCESS="false"
      FAIL_REASON="Agent emitted TASK_DONE but did not post a result comment with deterministic marker for attempt $current_attempt"
    fi
  fi
  
  # 7.5. Verify repository state is clean (no staged/unstaged/untracked changes)
  if [ "$SUCCESS" = "true" ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR/.git" ]; then
    local repo_state_clean="true"
    local repo_state_issues=""

    # Check for staged changes
    if ! git -C "$WORKDIR" diff --cached --quiet 2>/dev/null; then
      repo_state_clean="false"
      repo_state_issues+="staged_changes "
    fi

    # Check for unstaged changes
    if ! git -C "$WORKDIR" diff --quiet 2>/dev/null; then
      repo_state_clean="false"
      repo_state_issues+="unstaged_changes "
    fi

    # Check for untracked files (ignoring build artifacts like __pycache__)
    local untracked
    untracked="$(git -C "$WORKDIR" ls-files --others --exclude-standard 2>/dev/null | grep -v '/__pycache__' | grep -v '/\.pytest_cache' | grep -v '^__pycache__' | grep -v '^\.__pycache__' | grep -v '^\.__pycache__/' | grep -v '^\.pytest_cache' || true)"
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
  
  # 7.6 Determine whether the agent actually changed repository state.
  # Informational tasks may legitimately finish without a branch or PR.
  if [ "$SUCCESS" = "true" ]; then
    local repo_changed="false"
    if repository_changed_since "$WORKDIR" "$INITIAL_HEAD"; then repo_changed="true"; fi
    if [ "$repo_changed" = "true" ]; then
      local current_branch
      current_branch="$(git -C "$WORKDIR" symbolic-ref --short HEAD 2>/dev/null || echo "")"
      if [ -z "$current_branch" ]; then
        SUCCESS="false"
        FAIL_REASON="Repository changed but the agent is not on a named branch"
        log "dispatch: task $COMMENT_ID changed repository state from detached HEAD"
      elif [ "$current_branch" = "$DEFAULT_BRANCH" ] || [ "$current_branch" = "$INITIAL_BRANCH" ]; then
        SUCCESS="false"
        FAIL_REASON="Repository changes were made directly on a base/default branch ($current_branch)"
        log "dispatch: task $COMMENT_ID changed repository on forbidden base branch $current_branch"
        lc_log "TASK_ERROR" "task=$COMMENT_ID reason=changes_on_base_branch branch=$current_branch"
      elif ! verify_required_pr "$REPO" "$COMMENT_ID" "$WORKDIR" "$INITIAL_BASE_BRANCH"; then
        SUCCESS="false"
        FAIL_REASON="Implementation task did not produce a real PR against its branch base"
        log "dispatch: task $COMMENT_ID PR verification failed"
      else
        local verified_base
        verified_base="$(infer_task_base_branch "$WORKDIR" "$current_branch" "$INITIAL_BASE_BRANCH")"
        if ! verify_result_comment_pr_url "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt" "$WORKDIR" "$verified_base" "$current_branch"; then
          SUCCESS="false"
          FAIL_REASON="Result comment did not contain the exact canonical URL of the verified PR"
          log "dispatch: task $COMMENT_ID result comment PR URL verification failed"
        else
          log "dispatch: task $COMMENT_ID has repository changes on branch $current_branch; PR and result URL verified"
        fi
      fi
    else
      log "dispatch: task $COMMENT_ID made no repository changes; PR/branch not required"
      lc_log "NO_REPO_CHANGE" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM"
    fi
  fi

  # 8. Update SQLite using enhanced finalization with verification
  if [ "$SUCCESS" = "true" ]; then
    # Enhanced task completion with verification
    if complete_task_with_verification "$COMMENT_ID"; then
      COMPLETION_SUCCESS="true"
    else
      log "ERROR: Enhanced task completion failed for $COMMENT_ID, falling back to basic completion"
      # Fallback: attempt direct completion with ownership verification
      local fallback_worker_pid
      fallback_worker_pid="$BASHPID"
      local fallback_claim_token
      fallback_claim_token="$(sql_escape "$CLAIM_TOKEN")"
      local fallback_result
      fallback_result="$(sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL WHERE commentId='$safe_comment_id' AND status='running' AND workerPid=$fallback_worker_pid AND claimToken='$fallback_claim_token'; SELECT changes();" 2>/dev/null)"
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
}

run_once() {
  configure_task_retention
  cleanup_expired_tasks

  # Use timeout to prevent daemon deadlock if poll.sh hangs
  # This can happen if gh API is unresponsive or network is blocked.
  # The default scales with the number of configured repositories so one
  # slow repo (per-repo timeout) cannot starve the whole cycle: each repo
  # gets REPO_POLL_TIMEOUT + 10s buffer, with a 60s floor.
  local poll_timeout="${MANUL_POLL_TIMEOUT:-$(( ${#REPOS[@]} * (REPO_POLL_TIMEOUT + 10) + 60 ))}"
  # Capture poll.sh output to a file so a partial result emitted by poll.sh's
  # signal trap (when the global timeout kills it mid-cycle) is NOT lost.
  # Without this, every interrupted cycle reports fire:false and the daemon
  # never dispatches the queued task.
  local poll_out_file
  poll_out_file="$(mktemp)"
  local poll_rc=0
  timeout "$poll_timeout" "$POLL" >"$poll_out_file" 2>&1 || poll_rc=$?
  local out
  out="$(cat "$poll_out_file" 2>/dev/null)"
  rm -f "$poll_out_file"

  if [ "$poll_rc" -ne 0 ]; then
    if [ "$poll_rc" -eq 124 ]; then
      log "WARN: poll.sh hit global timeout after ${poll_timeout}s; using any partial result it emitted before dying"
      lc_log "POLL_TIMEOUT" "timeout=${poll_timeout}s"
      pkill -f "bash.*$POLL" 2>/dev/null || true
    else
      log "ERROR: poll.sh failed with rc=$poll_rc"
      lc_log "POLL_ERROR" "rc=$poll_rc"
    fi
  fi

  # Record poll result for observability. poll.sh writes diagnostics to stderr,
  # so stdout+stderr can contain arbitrary lines around the final MANUL_RESULT.
  # Parse exactly one complete MANUL_RESULT line and validate it before reading fields.
  local poll_fire poll_new poll_pending
  IFS='|' read -r poll_fire poll_new poll_pending < <(parse_poll_result "$out")
  record_poll "$poll_fire" "$poll_new" "$poll_pending"

  if [ "$poll_fire" = "true" ]; then
    log "dispatch: $out"
    lc_log "POLL" "fire=true new=$poll_new pending=$poll_pending"
  else
    lc_log "POLL" "fire=false new=$poll_new pending=$poll_pending"
  fi

  # Reconcile the workspace pool on every cycle. A long-lived daemon must not
  # rely on start() because the watchdog may clean stale idle workspaces later.
  if ! ensure_workspace_pool; then
    log "dispatch: workspace pool reconciliation failed"
    lc_log "WORKSPACE_POOL_ERROR" "need=$MAX_CONCURRENT_TASKS"
  fi

  # SQLite is the authoritative task queue. poll_fire is only a wake-up hint:
  # an existing eligible queued task must still be dispatched even when poll
  # output is malformed, stale, or reports fire=false.
  local eligible_queued
  eligible_queued="$(eligible_queued_count)"
  if [ "$poll_fire" != "true" ] && [ "${eligible_queued:-0}" -eq 0 ]; then
    return 0
  fi
  if [ "$poll_fire" != "true" ]; then
    log "dispatch: poll fire=false but SQLite has eligible queued task(s); dispatching from queue"
    lc_log "QUEUE_WAKEUP" "eligible=$eligible_queued"
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
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='queued' AND attempts >= $MAX_ATTEMPTS;" 2>/dev/null
      local FINAL_COMMENT="❌ Manul failed to complete the task after $ACTUAL_ATTEMPTS attempts (max reached)."
      post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" "$REPLY_TO" || log "WARN: failed to post final comment for $COMMENT_ID"
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi

    # 2. Atomically claim the task (queued -> running, attempts+1)
    # Prevent claiming if another worker already owns this task
    local CURRENT_WORKER_PID
    CURRENT_WORKER_PID="$BASHPID"
    local CLAIM_TOKEN
    CLAIM_TOKEN="$(printf '%s-%s-%s' "$(date +%s%N)" "$CURRENT_WORKER_PID" "$RANDOM")"
    local safe_claim_token
    safe_claim_token="$(sql_escape "$CLAIM_TOKEN")"
    local CLAIM_RESULT
    CLAIM_RESULT="$(sqlite3 "$DB" "UPDATE processed_comments SET status='running', attempts=attempts+1, processedAt=datetime('now'), heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now', '+${LEASE_TIMEOUT} seconds'), workerPid=$CURRENT_WORKER_PID, claimToken='$safe_claim_token' WHERE commentId='$safe_comment_id' AND status='queued' AND (workerPid IS NULL OR workerPid=0); SELECT changes();" 2>/dev/null)"

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
    local COMMENT_URL AUTHOR AGENT TASK_PROMPT TASK_CONTEXT TASK_ACTION
    COMMENT_URL="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    AUTHOR="$(sqlite3 "$DB" "SELECT author FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    AGENT="$(sqlite3 "$DB" "SELECT agent FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_PROMPT="$(sqlite3 "$DB" "SELECT prompt FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_CONTEXT="$(sqlite3 "$DB" "SELECT context FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_ACTION="$(sqlite3 "$DB" "SELECT action FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_ACTION="${TASK_ACTION:-IMPLEMENT}"

    # Self-heal legacy issuebody tasks whose issueNumber contains the GitHub
    # API object ID instead of the human-facing issue number.
    if [[ "$COMMENT_ID" == issuebody:* && "$COMMENT_URL" =~ /issues/([0-9]+)(/|#|$) ]]; then
      local source_issue_num="${BASH_REMATCH[1]}"
      if [ "$ISSUE_NUM" != "$source_issue_num" ]; then
        log "dispatch: correcting issuebody $COMMENT_ID issueNumber $ISSUE_NUM -> $source_issue_num from source URL"
        ISSUE_NUM="$source_issue_num"
      fi
    fi

    log "dispatch: claimed task $COMMENT_ID ($REPO#$ISSUE_NUM), attempts now $((ACTUAL_ATTEMPTS + 1))"
    lc_log "CLAIMED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempts=$((ACTUAL_ATTEMPTS + 1))"
    local current_attempt=$((ACTUAL_ATTEMPTS + 1))
    set_activity "$COMMENT_ID" "claimed"

    # 3.5 Pre-flight source revalidation — terminal if source no longer valid
    local reval_rc=0
    revalidate_source "$COMMENT_ID" "$REPO" "$ISSUE_NUM" "$COMMENT_URL" || reval_rc=$?
    if [ "$reval_rc" -eq 1 ]; then
      log "dispatch: source stale for task $COMMENT_ID, marking terminal"
      lc_log "SOURCE_STALE_REVAL" "task=$COMMENT_ID repo=$REPO rc=$reval_rc"
      mark_task_stale "$COMMENT_ID" "$safe_comment_id" "$CLAIM_TOKEN"
      stop_heartbeat "$COMMENT_ID"
      release_repo_lock "$REPO"
      release_task_lock
      set_activity "none" "idle"
      return 0
    elif [ "$reval_rc" -eq 2 ]; then
      log "dispatch: source transient error for task $COMMENT_ID, requeuing"
      lc_log "SOURCE_TRANSIENT_REVAL" "task=$COMMENT_ID repo=$REPO rc=$reval_rc"
      requeue_task "$COMMENT_ID" "$safe_comment_id" "$CLAIM_TOKEN"
      stop_heartbeat "$COMMENT_ID"
      release_repo_lock "$REPO"
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi

    # Start heartbeat for long-running task
    start_heartbeat "$COMMENT_ID" "$CURRENT_WORKER_PID" "$CLAIM_TOKEN"
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
      sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token';" 2>/dev/null
      stop_heartbeat "$COMMENT_ID"
      release_repo_lock "$REPO"
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi

    log "dispatch: posted in-progress comment for $COMMENT_ID"

    # 4b. Emit TASK_STARTED event marker (GitHub control protocol)
    lc_log "TASK_STARTED_EMITTED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM"
    if [ -f "${MANUL_DIR}/manul-result-feedback.sh" ]; then
      task_conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
      task_pr_num="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
      "$MANUL_DIR/manul-result-feedback.sh" post-started \
        --repo "$REPO" \
        --issue "$ISSUE_NUM" \
        --comment-id "$COMMENT_ID" \
        --task-id "$COMMENT_ID" \
        --pr-number "${task_pr_num:-}" \
        --json >>"$LOG" 2>&1 || log "WARN: failed to post TASK_STARTED event for $COMMENT_ID"
    fi

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
- Task Action: __TASK_ACTION__
- PR Number: __PR_NUMBER__
- Original Review Comment ID: __REPLY_TO__

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

## User interaction and decision points
1. Behave like a competent human teammate.
2. Make straightforward, low-risk decisions autonomously.
3. You may proactively propose a concrete solution, improvement, trade-off, or next step when you have enough information.
4. Do not ask the user merely because two equivalent implementations exist.
5. When multiple materially different valid approaches would change architecture, behavior, scope, compatibility, data model, UX, or another important outcome, involve the user.
6. When more than two materially different viable directions remain, briefly present the options and ask what to do next.
7. You may recommend one option and explain why, but leave the final choice to the user.
8. Before asking, inspect the repository, relevant skills/docs, configuration, and conversation context.
9. Do not guess when missing information materially affects correctness.
10. Once user input is required, avoid further irreversible repository changes and emit:
`TASK_NEEDS_USER_BEGIN`
<question/options>
`TASK_NEEDS_USER_END`
11. Do not emit `TASK_DONE` or `TASK_FAILED` in the same run as `TASK_NEEDS_USER_BEGIN/END`.

## Rules
1. Inspect the local repository and implement the requested change.
2. Run appropriate tests/validation.
3. Make the requested code changes.
4. When finished, output exactly: `TASK_DONE`
5. If the task is blocked on a user decision, emit the TASK_NEEDS_USER block above.
6. If you cannot complete the task for a non-user-input failure, output exactly: `TASK_FAILED: <brief reason>`
7. Do NOT modify `manul.db`.
8. Do NOT manage Manul task state.

## GitHub Comment Posting (CRITICAL)
You MUST post exactly one user-facing result comment to GitHub using the `run` tool.

### Routing
Use the task metadata above and choose the endpoint that matches `Task Type`:

- For `pr_review_comment`: reply to the existing inline review thread. Use the PR review-comments endpoint and the original review comment ID:
```bash
gh api repos/__REPO__/pulls/__PR_NUMBER__/comments \
  -f body="YOUR_REPLY" \
  -f in_reply_to=__REPLY_TO__ \
  --jq .id
```

- For `pr_conversation_comment` or an issue task: post a top-level conversation comment:
```bash
gh api repos/__REPO__/issues/__ISSUE_NUM__/comments \
  -f body="YOUR_RESULT_COMMENT" \
  --jq .id
```

Do NOT use `/issues/__ISSUE_NUM__/comments` with `in_reply_to`: that endpoint does not create replies to inline PR review threads.
Replace REPO, PR_NUMBER, ISSUE_NUM, and the result body with the actual values from this prompt.

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

The daemon handles lifecycle comments (🔄 working, ✅ completed, ❌ failed, ❓ needs user).
For a normal task, you handle the result comment. When you emit TASK_NEEDS_USER_BEGIN/END, do NOT post a normal result comment; the daemon will post the question and resume the same task after the user replies.
PROMPT_EOF

    # Repository Management: Ensure target repository exists and is authoritative
    local REPO_DIR
    REPO_DIR="$(ensure_repo "$REPO")"
    if [ $? -ne 0 ]; then
      log "dispatch: FAILED to ensure repository $REPO, failing task"
      lc_log "TASK_ERROR" "task=$COMMENT_ID reason=repo_unavailable repo=$REPO"
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token';" 2>/dev/null
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
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token';" 2>/dev/null
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

    # 6.5. Lease workspace for exclusive task access
    source "$MANUL_DIR/workspace-manager.sh"
    local WORKSPACE_ID
    WORKSPACE_ID="$(workspace_lease "$COMMENT_ID")"
    if [ -z "$WORKSPACE_ID" ]; then
      log "dispatch: no workspace available for task $COMMENT_ID, retrying"
      lc_log "NO_WORKSPACE" "task=$COMMENT_ID repo=$REPO"
      sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token';" 2>/dev/null
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi
    
    # Update task with workspace association
    sqlite3 "$DB" "UPDATE processed_comments SET workspaceId='$WORKSPACE_ID' WHERE commentId='$safe_comment_id';"
    
    # If conversation has a previously used workspace, try to reuse it
    local conversation_id
    conversation_id="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    if [ -n "$conversation_id" ]; then
      local prev_workspace
      prev_workspace="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE conversationId='$conversation_id' AND status IN ('completed','failed') ORDER BY processedAt DESC LIMIT 1;" 2>/dev/null)"
      if [ -n "$prev_workspace" ]; then
        # Release the newly leased workspace and re-lease the previous one
        workspace_release "$WORKSPACE_ID" "$COMMENT_ID"
        WORKSPACE_ID="$prev_workspace"
        sqlite3 "$DB" "UPDATE processed_comments SET workspaceId='$WORKSPACE_ID' WHERE commentId='$safe_comment_id';"
        log "dispatch: reusing previous workspace $WORKSPACE_ID for conversation $conversation_id"
      fi
    fi


    # Get workspace path from lease
    local workspace_path
    workspace_path="$(workspace_get_path "$COMMENT_ID")"
    if [ -z "$workspace_path" ]; then
      log "dispatch: could not get workspace path for $COMMENT_ID, releasing and failing"
      workspace_release "$WORKSPACE_ID" "$COMMENT_ID"
      stop_heartbeat "$COMMENT_ID"
      release_repo_lock "$REPO"
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi

    # Clone repository into workspace if needed
    if [ ! -d "$workspace_path/.git" ]; then
      log "dispatch: cloning repository into workspace $workspace_path from $REPO_DIR"
      git clone --local "$REPO_DIR" "$workspace_path" 2>/dev/null || {
        log "dispatch: failed to clone repository into workspace, releasing and failing"
        workspace_release "$WORKSPACE_ID" "$COMMENT_ID"
        stop_heartbeat "$COMMENT_ID"
        release_repo_lock "$REPO"
        release_task_lock
        set_activity "none" "idle"
        return 0
      }
      # Fix origin remote: git clone --local sets origin to the local path,
      # but the agent needs to push to GitHub. Update origin to point to GitHub.
      git -C "$workspace_path" remote set-url origin "https://github.com/${REPO}" 2>>"$LOG"
      log "dispatch: updated workspace origin to https://github.com/${REPO}"
    fi

# Use the workspace as the working directory for the agent
     WORKDIR="$workspace_path"

     # Deterministic workspace preparation: ensure correct branch is checked out
     if [ -n "$PR_HEAD_BRANCH" ]; then
      # PR task: fetch and checkout the PR head branch explicitly
      log "dispatch: preparing PR head branch $PR_HEAD_BRANCH in workspace $WORKDIR"
      if ! git -C "$WORKDIR" fetch origin "$PR_HEAD_BRANCH" 2>>"$LOG"; then
        log "dispatch: failed to fetch PR head branch, releasing and failing"
        workspace_release "$WORKSPACE_ID" "$COMMENT_ID"
        stop_heartbeat "$COMMENT_ID"
        release_repo_lock "$REPO"
        release_task_lock
        set_activity "none" "idle"
        return 0
      fi
      if ! git -C "$WORKDIR" checkout -B "$PR_HEAD_BRANCH" "FETCH_HEAD" 2>>"$LOG"; then
        log "dispatch: failed to checkout PR head branch, releasing and failing"
        workspace_release "$WORKSPACE_ID" "$COMMENT_ID"
        stop_heartbeat "$COMMENT_ID"
        release_repo_lock "$REPO"
        release_task_lock
        set_activity "none" "idle"
        return 0
      fi
      # Verify HEAD is the expected PR head branch
      local verify_branch
      verify_branch="$(git -C "$WORKDIR" symbolic-ref --short HEAD 2>/dev/null)"
      if [ "$verify_branch" != "$PR_HEAD_BRANCH" ]; then
        log "dispatch: PR branch verification failed (expected=$PR_HEAD_BRANCH, got=$verify_branch), releasing and failing"
        workspace_release "$WORKSPACE_ID" "$COMMENT_ID"
        release_repo_lock "$REPO"
        release_task_lock
        set_activity "none" "idle"
        return 0
      fi
log "dispatch: verified PR head branch $verify_branch in workspace"
     else
       # Issue / standalone task: the workspace may have been left on a stale
       # task branch from a previous run. Reset to the default branch so the
       # agent starts from a clean, known state and cannot pick up leftover
       # changes from an unrelated task. (Do NOT use clean -fdx: the workspace
       # holds untracked helper dirs like .agents that must be preserved.)
       local default_branch
       default_branch="$(git -C "$WORKDIR" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}' || echo "")"
       local base_branch
       base_branch="$(determine_task_base_branch "$WORKDIR" "$default_branch")"
       log "dispatch: preparing workspace $WORKDIR from base branch '$base_branch' for task $COMMENT_ID"
       if ! git -C "$WORKDIR" fetch origin --quiet 2>>"$LOG"; then
         log "ERROR: failed to fetch origin before task setup on $REPO"
         workspace_release "$WORKSPACE_ID" "$COMMENT_ID"; stop_heartbeat "$COMMENT_ID"; release_repo_lock "$REPO"; release_task_lock; set_activity "none" "idle"; return 0
       fi
       base_branch="$(determine_task_base_branch "$WORKDIR" "$default_branch")"
       if ! git -C "$WORKDIR" checkout -B "$base_branch" "origin/$base_branch" 2>>"$LOG"; then
         log "ERROR: failed to checkout base branch '$base_branch' for task $COMMENT_ID"
         workspace_release "$WORKSPACE_ID" "$COMMENT_ID"; stop_heartbeat "$COMMENT_ID"; release_repo_lock "$REPO"; release_task_lock; set_activity "none" "idle"; return 0
       fi
       if ! git -C "$WORKDIR" reset --hard "origin/$base_branch" --quiet 2>>"$LOG"; then
         log "ERROR: failed to reset workspace to origin/$base_branch for task $COMMENT_ID"
         workspace_release "$WORKSPACE_ID" "$COMMENT_ID"; stop_heartbeat "$COMMENT_ID"; release_repo_lock "$REPO"; release_task_lock; set_activity "none" "idle"; return 0
       fi
       if ! git -C "$WORKDIR" clean -fd --quiet 2>>"$LOG"; then
         log "ERROR: failed to clean workspace before task $COMMENT_ID"
         workspace_release "$WORKSPACE_ID" "$COMMENT_ID"; stop_heartbeat "$COMMENT_ID"; release_repo_lock "$REPO"; release_task_lock; set_activity "none" "idle"; return 0
       fi
     fi
     log "dispatch: task $COMMENT_ID repository located at $REPO_DIR, workspace=$WORKSPACE_ID ($WORKDIR)"

    # Capture the exact repository state we hand to the agent.
    local CURRENT_BRANCH
    CURRENT_BRANCH="$(git -C "$WORKDIR" symbolic-ref --short HEAD 2>/dev/null || echo "UNKNOWN")"
    local INITIAL_BRANCH="$CURRENT_BRANCH"
    local INITIAL_HEAD
    INITIAL_HEAD="$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || echo "")"
    local DEFAULT_BRANCH
    DEFAULT_BRANCH="$(git -C "$WORKDIR" remote show origin 2>/dev/null | grep "HEAD" | awk '{print $3}' || echo "")"
    local INITIAL_BASE_BRANCH="${base_branch:-$CURRENT_BRANCH}"
    log "dispatch: task $COMMENT_ID starts on branch=$INITIAL_BRANCH head=$INITIAL_HEAD initialBase=$INITIAL_BASE_BRANCH default=$DEFAULT_BRANCH"

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
- PR head branch `__PR_HEAD_BRANCH__` is already checked out and ready for work
- Commit and push changes to the same PR head branch
- Do NOT create a new branch for this task
PROMPT_APPEND
    else
      # Standalone issue task: daemon prepares the base; the agent owns the
      # repository-change branch decision and follows feature-branching-strategy.
      cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'
- This is a standalone task (not tied to an existing PR)
- Current branch: __CURRENT_BRANCH__
- Repository default branch: __DEFAULT_BRANCH__
- Initial prepared base branch: __INITIAL_BASE_BRANCH__
- The daemon does NOT create your task branch for you
- First determine whether this is informational or requires repository changes
- For informational tasks: do NOT modify the repository and do NOT create a branch; post the answer to GitHub and finish
- For repository changes: read and follow `~/.agents/skills/feature-branching-strategy/SKILL.md` as the authoritative branching policy
- Create the branch yourself before committing or pushing changes
- If the task explicitly requires another branch as the base, including another feature branch, use it as the base and update it from the remote before creating your branch
- Never commit or push repository changes directly to the prepared/base/default branch
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
    prompt_content="${prompt_content//__TASK_ACTION__/$TASK_ACTION}"
    prompt_content="${prompt_content//__PR_NUMBER__/$ISSUE_NUM}"
    prompt_content="${prompt_content//__REPLY_TO__/$REPLY_TO}"
    prompt_content="${prompt_content//__CURRENT_ATTEMPT__/$current_attempt}"
    prompt_content="${prompt_content//__REPO_DIR__/$REPO_DIR}"
    prompt_content="${prompt_content//__WORKDIR__/$WORKDIR}"
    prompt_content="${prompt_content//__PR_HEAD_BRANCH__/$PR_HEAD_BRANCH}"
    prompt_content="${prompt_content//__CURRENT_BRANCH__/$CURRENT_BRANCH}"
    prompt_content="${prompt_content//__DEFAULT_BRANCH__/$DEFAULT_BRANCH}"
    prompt_content="${prompt_content//__INITIAL_BASE_BRANCH__/$INITIAL_BASE_BRANCH}"
    printf '%s' "$prompt_content" > "$TASK_PROMPT_FILE"

    # 6. Invoke implementation agent with the per-task prompt, ensuring proper working directory
    local STDOUT_FILE="$MANUL_DIR/tasks/task-${COMMENT_ID}.stdout"
    local STDERR_FILE="$MANUL_DIR/tasks/task-${COMMENT_ID}.stderr"

    log "dispatch: invoking agent manul for task $COMMENT_ID"
    lc_log "WORKER_START" "task=$COMMENT_ID repo=$REPO timeout=${AGENT_TIMEOUT}s"
    set_activity "$COMMENT_ID" "working"

    # 5. Invoke agent with timeout to prevent daemon deadlock
    # Use timeout to kill the entire process tree if agent hangs
    # The timeout command sends SIGTERM after AGENT_TIMEOUT, then SIGKILL after 60s.
    # The wrapper also passes an explicit OpenClaw timeout so its 600s CLI default
    # can never terminate a normal coding task before Manul's outer deadline.
     # Change to repository directory and invoke agent
     local prev_dir
     prev_dir="$(pwd)"
     cd "$WORKDIR" || {
       log "ERROR: cannot enter working directory $WORKDIR, failing task"
       stop_heartbeat "$COMMENT_ID"
       workspace_release "$WORKSPACE_ID" "$COMMENT_ID"
       release_repo_lock "$REPO"
       release_task_lock
       set_activity "none" "idle"
       return 0
     }
     # Ensure skill visibility for the OpenCode process
     export OPENCODE_SKILLS_PATH="$HOME/.agents/skills"
     # Leave a 1,500s grace window between the OpenClaw inner timeout (12h)
     # and the daemon hard deadline (12h 5m) so the wrapper can record failure
     # diagnostics and emit its terminal marker deterministically.
     export MANUL_OPENCLAW_AGENT_TIMEOUT="${MANUL_OPENCLAW_AGENT_TIMEOUT:-43200}"
     # Refresh heartbeat before agent to prevent timeout during long runs
     refresh_heartbeat "$COMMENT_ID"
     timeout -k 60 "$AGENT_TIMEOUT" "$MANUL_DIR/manul-agent-wrapper.sh" "$TASK_PROMPT_FILE" "$STDOUT_FILE" "$STDERR_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE"
     local rc=$?
     cd "$prev_dir" 2>/dev/null || log "WARN: failed to restore working directory"

     # Preserve launcher diagnostics in daemon.log before task artifacts are cleaned
     # up. This is especially important for fast launch failures where the worker
     # can exit before producing a GitHub-visible result.
     if [ "$rc" -ne 0 ]; then
       log "dispatch: agent launcher exited rc=$rc for task $COMMENT_ID"
       if [ -s "$STDERR_FILE" ]; then
         log "dispatch: agent stderr for task $COMMENT_ID (tail 80):"
         tail -n 80 "$STDERR_FILE" >>"$LOG" 2>/dev/null || true
       else
         log "dispatch: agent stderr file is empty for task $COMMENT_ID"
       fi
     fi

    # Call production completion evaluation function
    evaluate_task_completion "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt" "$rc" "$STDOUT_FILE" "$DB" "$REPO_DIR" "$WORKDIR" "$CLAIM_TOKEN" "$INITIAL_HEAD" "$INITIAL_BRANCH" "$INITIAL_BASE_BRANCH"

    # A structured TASK_NEEDS_USER result pauses this task without entering the
    # worker failure/retry path. The daemon asks the user and then waits for an
    # explicit /manul continue response.
    if [ "${NEEDS_USER_INPUT:-false}" = "true" ]; then
      if mark_task_blocked_user "$COMMENT_ID" "$safe_comment_id" "$CLAIM_TOKEN"; then
        if [ -n "${WORKSPACE_ID:-}" ]; then
          workspace_release "$WORKSPACE_ID" "$COMMENT_ID" || log "WARN: failed to release workspace after user-blocked task $COMMENT_ID"
        fi
        if ! post_task_needs_user_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$USER_QUESTION" "$REPLY_TO"; then
          log "WARN: failed to post TASK_NEEDS_USER comment for $COMMENT_ID"
        fi
        stop_heartbeat "$COMMENT_ID"
        release_repo_lock "$REPO"
        release_task_lock
        set_activity "$COMMENT_ID" "blocked_user"
        return 0
      fi
      log "ERROR: could not transition $COMMENT_ID to blocked_user; falling through to failure handling"
      NEEDS_USER_INPUT="false"
    fi

    # Map local variables (set by evaluate_task_completion)
    COMPLETION_SUCCESS="${COMPLETION_SUCCESS:-false}"
    FINAL_COMMENT="${FINAL_COMMENT:-}"
    FAIL_REASON="${FAIL_REASON:-}"

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
      
      # Save result metadata for local API access
      local result_json=""
      if [ -f "$STDOUT_FILE" ]; then
        # Extract JSON from stdout if present (after TASK_DONE marker)
        result_json="$(grep -A 100 'TASK_DONE' "$STDOUT_FILE" 2>/dev/null | tail -n +2 | head -1 | tr -d '\n' || echo "")"
      fi
      
      # Escape for SQL
      local escaped_summary escaped_result
      escaped_summary="$(printf '%s' "$REPO#$ISSUE_NUM" | sed "s/'/''/g")"
      escaped_result="$(printf '%s' "$result_json" | sed "s/'/''/g")"
      
      sqlite3 "$DB" "UPDATE processed_comments SET 
        resultSummary='$escaped_summary', 
        resultJson='$escaped_result'
        WHERE commentId='$safe_comment_id';" 2>/dev/null
      
      set_activity "$COMMENT_ID" "completed"
    elif [ "${NEW_ATTEMPTS:-0}" -ge "$MAX_ATTEMPTS" ]; then
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token';" 2>/dev/null
    else
      sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token';" 2>>"$LOG"
    fi

    # Auto-close conversation when all tasks are finalized (completed or failed).
    # Skip if the task was requeued for retry.
    local task_final_status
    task_final_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
    if [ "$task_final_status" = "completed" ] || [ "$task_final_status" = "failed" ]; then
      local task_conv_id_for_close
      task_conv_id_for_close="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
      if [ -n "$task_conv_id_for_close" ]; then
        local remaining_tasks
        remaining_tasks="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$(sql_escape "$task_conv_id_for_close")' AND status IN ('queued', 'running', 'blocked_user');" 2>>"$LOG")" || remaining_tasks=""
        if [ -z "$remaining_tasks" ]; then
          log "ERROR: failed to count remaining tasks for conversation $task_conv_id_for_close (task drain)"
        elif [ "$remaining_tasks" -eq 0 ]; then
          local now_close
          now_close="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          if sqlite3 "$DB" "UPDATE conversations SET status='COMPLETED', activePrNumber=NULL, activePrUrl=NULL, updatedAt='$now_close' WHERE conversationId='$(sql_escape "$task_conv_id_for_close")' AND status != 'COMPLETED';" 2>>"$LOG"; then
            log "auto-closed conversation $task_conv_id_for_close (all tasks finalized, status=$task_final_status)"
          else
            log "ERROR: failed to close conversation $task_conv_id_for_close (task drain)"
          fi
        fi
      fi
    fi

    # Stop heartbeat after task completion/failure
    stop_heartbeat "$COMMENT_ID"
    lc_log "HEARTBEAT_STOP" "task=$COMMENT_ID"

    # GitHub control protocol: post structured result feedback
    if [ -f "${MANUL_DIR}/manul-result-feedback.sh" ]; then
      task_attempt="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "1")"
      task_conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
      task_pr_num="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
      if [ "$COMPLETION_SUCCESS" = "true" ]; then
        # Extract summary from result
        local result_summary=""
        if [ -f "$STDOUT_FILE" ]; then
          result_summary="$(grep -oP '(?<=TASK_DONE\s).+' "$STDOUT_FILE" 2>/dev/null | head -1 || echo "")"
        fi
        "$MANUL_DIR/manul-result-feedback.sh" post-done \
          --repo "$REPO" \
          --issue "$ISSUE_NUM" \
          --comment-id "$COMMENT_ID" \
          --task-id "$COMMENT_ID" \
          --summary "${result_summary:-Task completed successfully}" \
          --pr-number "${task_pr_num:-}" \
          --json >>"$LOG" 2>&1 || log "WARN: failed to post TASK_DONE event for $COMMENT_ID"
      else
        fail_reason="${FAIL_REASON:-Task failed}"
        "$MANUL_DIR/manul-result-feedback.sh" post-failed \
          --repo "$REPO" \
          --issue "$ISSUE_NUM" \
          --comment-id "$COMMENT_ID" \
          --task-id "$COMMENT_ID" \
          --error "${fail_reason:0:500}" \
          --pr-number "${task_pr_num:-}" \
          --json >>"$LOG" 2>&1 || log "WARN: failed to post TASK_FAILED event for $COMMENT_ID"
      fi
    fi

    # Release workspace back to pool
    local task_workspace_id
    task_workspace_id="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    if [ -n "$task_workspace_id" ]; then
      workspace_release "$task_workspace_id" "$COMMENT_ID"
      log "dispatch: released workspace $task_workspace_id for task $COMMENT_ID"
      lc_log "WORKSPACE_RELEASE" "task=$COMMENT_ID workspace=$task_workspace_id"
    fi

    # Release repository lock
    release_repo_lock "$REPO"

    # Cleanup task artifacts (no separate workdir to remove)
    rm -f "$TASK_PROMPT_FILE" "$STDOUT_FILE" "$STDERR_FILE"

    release_task_lock
    set_activity "none" "idle"
}

loop() {
  # Parse arguments for worker mode
  local worker_id=""
  for arg in "$@"; do
    case "$arg" in
      --worker=*) worker_id="${arg#--worker=}" ;;
    esac
  done

  # Ensure nextAttemptAt column exists before any scheduler query
  if ! ensure_nextattemptat_column; then
    log "FATAL: schema migration failed, cannot start loop"
    exit 1
  fi

  # Ensure task claim ownership support before any claim/recovery.
  if ! ensure_claim_token_column; then
    log "FATAL: claimToken schema migration failed, cannot start loop"
    exit 1
  fi

  # Recover any stale tasks from previous crashes/deadlocks
  recover_stale_tasks

  # Source workspace manager
  source "$MANUL_DIR/workspace-manager.sh"

  # In worker mode, skip flock (each worker has its own lock)
  if [ -n "$worker_id" ]; then
    log "daemon loop started as worker $worker_id (interval ${INTERVAL}s)"
    lc_log "LOOP_START" "worker=$worker_id interval=${INTERVAL}s"
    while true; do
      run_once
      sleep "$INTERVAL"
    done
  else
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
  fi
}

# Source guard: prevent CLI execution when sourced for testing
MANUL_TESTING="${MANUL_TESTING:-false}"
if [[ "${MANUL_TESTING}" == "true" ]]; then
  return 0
fi

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  run-once) run_once ;;
  loop) shift; loop "$@" ;;
  *) echo "usage: $0 start|stop|status|run-once [loop]" >&2; exit 2 ;;
esac
