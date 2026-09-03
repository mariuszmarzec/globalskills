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

# Get daemon PID for ownership tracking
CURRENT_DAEMON_PID="$(cat "$PID_FILE" 2>/dev/null || echo "")"

# Heartbeat management functions
start_heartbeat() {
  local task_id="$1"
  local pid_file="$MANUL_DIR/task-${task_id}.heartbeat.pid"
  local log_file="$MANUL_DIR/task-${task_id}.heartbeat.log"
  
  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    log "heartbeat already running for task $task_id"
    return 0
  fi
  
  (
    while true; do
      local now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      local safe_comment_id="$(sql_escape "$task_id")"
      # Renew lease and update heartbeat, but only if this task is still owned by us
      sqlite3 "$DB" "
        UPDATE processed_comments
        SET heartbeatAt='$now',
            leaseExpiresAt=datetime('$now', '+${LEASE_TIMEOUT} seconds')
        WHERE commentId='$safe_comment_id' AND status='running' AND workerPid=${CURRENT_DAEMON_PID:-0};
      " 2>/dev/null
      sleep "${HEARTBEAT_INTERVAL}"
    done
  ) >>"$log_file" 2>&1 &
  local heartbeat_pid=$!
  echo "$heartbeat_pid" >"$pid_file"
  log "started heartbeat for task $task_id (pid $heartbeat_pid)"
}

stop_heartbeat() {
  local task_id="$1"
  local pid_file="$MANUL_DIR/task-${task_id}.heartbeat.pid"
  
  if [ -f "$pid_file" ]; then
    local pid="$(cat "$pid_file" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      log "stopped heartbeat for task $task_id (pid $pid)"
    fi
    rm -f "$pid_file"
  fi
}

start() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PID_FILE"))"
    return 0
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
  gh issue comment "$issue" --repo "$repo" --body "$body" 2>>"$LOG"
}

run_once() {
  out="$("$POLL")"
  echo "$out"
  if printf '%s' "$out" | grep -q '"fire":true'; then
    log "dispatch: $out"

    # 1. Find oldest queued task
    TASK_ROW="$(sqlite3 "$DB" "SELECT commentId,repository,issueNumber,commentUrl,author,agent,prompt,context,attempts FROM processed_comments WHERE status='queued' ORDER BY createdAt ASC LIMIT 1;" 2>/dev/null)"

    if [ -z "$TASK_ROW" ]; then
      log "dispatch: fire:true but no queued task found"
      return 0
    fi

    IFS='|' read -r COMMENT_ID REPO ISSUE_NUM COMMENT_URL AUTHOR AGENT PROMPT CONTEXT ATTEMPTS <<< "$TASK_ROW"

    # Escape for SQL
    safe_comment_id="$(sql_escape "$COMMENT_ID")"
    safe_repo="$(sql_escape "$REPO")"

    # 2. Atomically claim the task (queued -> running, attempts+1)
    CLAIM_RESULT="$(sqlite3 "$DB" "UPDATE processed_comments SET status='running', attempts=attempts+1, processedAt=datetime('now'), heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now', '+900 seconds'), workerPid=${CURRENT_DAEMON_PID:-0} WHERE commentId='$safe_comment_id' AND status='queued'; SELECT changes();" 2>/dev/null)"

    CHANGED="$(echo "$CLAIM_RESULT" | tail -n 1)"

    if [ "${CHANGED:-0}" -ne 1 ]; then
      log "dispatch: task $COMMENT_ID not claimed (changed=$CHANGED)"
      return 0
    fi

    log "dispatch: claimed task $COMMENT_ID ($REPO#$ISSUE_NUM), attempts now $((ATTEMPTS + 1))"

    # Acquire lock before invoking agent
    [ -f "$LOCK" ] || date +%s >"$LOCK"

    # Start heartbeat for long-running task
    start_heartbeat "$COMMENT_ID"

    # 3. Post "in progress" comment BEFORE invoking the LLM
    IN_PROGRESS_BODY="🔄 Manul is working on this task..."

    if ! post_github_comment "$REPO" "$ISSUE_NUM" "$IN_PROGRESS_BODY"; then
      log "dispatch: FAILED to post in-progress comment for $COMMENT_ID, reverting to queued"
      stop_heartbeat "$COMMENT_ID"
      sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL WHERE commentId='$safe_comment_id';" 2>/dev/null
      rm -f "$LOCK"
      return 0
    fi

    log "dispatch: posted in-progress comment for $COMMENT_ID"

    # 4. Create per-task prompt containing the actual task payload
    TASK_PROMPT_DIR="$MANUL_DIR/tasks"
    mkdir -p "$TASK_PROMPT_DIR"
    TASK_PROMPT_FILE="$TASK_PROMPT_DIR/task-${COMMENT_ID}.md"

    # Determine task type from commentUrl metadata (do NOT call gh pr view)
    TASK_TYPE="issue"
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
$PROMPT

## Context
$CONTEXT

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

    # 5. Invoke implementation agent with the per-task prompt
    STDOUT_FILE="$MANUL_DIR/tasks/task-${COMMENT_ID}.stdout"
    STDERR_FILE="$MANUL_DIR/tasks/task-${COMMENT_ID}.stderr"

    log "dispatch: invoking agent manul for task $COMMENT_ID"

    timeout -k 60 "$AGENT_TIMEOUT" "$OPENCLAW_BIN" agent --agent manul --message-file "$TASK_PROMPT_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE"
    rc=$?

    log "dispatch: agent finished rc=$rc for task $COMMENT_ID"

    # 6. Determine success using BOTH exit status AND explicit completion marker
    SUCCESS="false"
    FAIL_REASON=""

    if [ $rc -eq 0 ]; then
      if grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
        SUCCESS="true"
      elif grep -q "^TASK_FAILED:" "$STDOUT_FILE"; then
        FAIL_REASON="$(grep "^TASK_FAILED:" "$STDOUT_FILE" | head -1 | sed 's/^TASK_FAILED: //')"
      fi
    fi

    # 7. Update SQLite and post final result
    FINAL_COMMENT=""
    if [ "$SUCCESS" = "true" ]; then
      sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt=datetime('now'), errorMessage=NULL WHERE commentId='$safe_comment_id';" 2>/dev/null
      FINAL_COMMENT="✅ Manul completed the task successfully."
      log "dispatch: task $COMMENT_ID completed successfully"
    else
      NEW_ATTEMPTS=$((ATTEMPTS + 1))
      MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // 3' "$CONFIG" 2>/dev/null || echo 3)"

      if [ "$NEW_ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
        sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), errorMessage='${FAIL_REASON:-Agent failed or did not emit TASK_DONE}' WHERE commentId='$safe_comment_id';" 2>/dev/null
        FINAL_COMMENT="❌ Manul failed to complete the task after $NEW_ATTEMPTS attempts.${FAIL_REASON:+ Reason: $FAIL_REASON}"
        log "dispatch: task $COMMENT_ID failed (max attempts reached)"
      else
        sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL WHERE commentId='$safe_comment_id';" 2>/dev/null
        FINAL_COMMENT="⚠️ Manul encountered an issue and will retry (attempt $NEW_ATTEMPTS/$MAX_ATTEMPTS).${FAIL_REASON:+ Reason: $FAIL_REASON}"
        log "dispatch: task $COMMENT_ID requeued for retry (attempt $NEW_ATTEMPTS)"
      fi
    fi

    # Stop heartbeat after task completion/failure
    stop_heartbeat "$COMMENT_ID"

    # 8. Post final result comment to the SAME GitHub thread
    if [ -n "$FINAL_COMMENT" ]; then
      post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" || log "WARN: failed to post final comment for $COMMENT_ID"
    fi

    rm -f "$LOCK"
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
