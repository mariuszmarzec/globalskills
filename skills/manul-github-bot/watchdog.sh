#!/bin/bash
# watchdog.sh — keep the manul daemon alive and recover from stale locks.
#
# Run from cron every 5 minutes:
#   */5 * * * * /home/marzec/.openclaw/manul/watchdog.sh
#
# Responsibilities:
#   1. Start the daemon if it is not running.
#   2. Detect a stale lock file (age >= LOCK_TTL) and remove it.
#   3. Reset tasks stuck in "running" state back to "queued" so the next
#      poll cycle can retry them (handles agent/crashes that left the DB dirty).
#
# New (2026-08-25): Proactive task health monitoring:
#   - Resets tasks stuck in 'running' for > MAX_RUNNING_TIME seconds (configurable)
#   - Marks failed tasks as 'failed' when they exceed max attempts
#   - Logs all stuck task detections for debugging
#
# Logs are written to ~/.openclaw/manul/watchdog.log
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="${MANUL_DIR}/config.json"
LOCK="$MANUL_DIR/lock"
PID_FILE="$MANUL_DIR/daemon.pid"
LOG="$MANUL_DIR/watchdog.log"
LOCK_TTL="${MANUL_LOCK_TTL_SECONDS:-1800}"  # 30 minutes — must match manul-daemon.sh
MAX_RUNNING_TIME="${MANUL_MAX_RUNNING_TIME:-900}"  # 15 minutes — max time a task should be 'running'

# Load config overrides if available
if [ -f "$CONFIG" ]; then
    CFG_MAX_RUNNING_TIME="$(jq -r '.automation.maxTaskRunningTime // empty' "$CONFIG" 2>/dev/null)"
    [ -n "$CFG_MAX_RUNNING_TIME" ] && MAX_RUNNING_TIME="$CFG_MAX_RUNNING_TIME"
    CFG_LOCK_TTL="$(jq -r '.automation.lockTtl // empty' "$CONFIG" 2>/dev/null)"
    [ -n "$CFG_LOCK_TTL" ] && LOCK_TTL="$CFG_LOCK_TTL"
    CFG_MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // empty' "$CONFIG" 2>/dev/null)"
fi

log() { echo "[$(date -Is)] $*" >> "$LOG"; }

# --- 1) daemon liveness ----------------------------------------------------
if ! [ -f "$PID_FILE" ] || ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
  log "daemon not running (no pid / pid not alive) → starting"
  "$MANUL_DIR/manul-daemon.sh" start >>"$LOG" 2>&1
  exit 0
fi

# --- 2) stale lock recovery ------------------------------------------------
if [ -f "$LOCK" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
  if [ "$age" -ge "$LOCK_TTL" ]; then
    log "stale lock detected (age=${age}s, ttl=${LOCK_TTL}s) → removing"
    rm -f "$LOCK"

    # --- 3) reset stuck "running" tasks in the DB --------------------------
    if [ -f "$MANUL_DIR/manul.db" ]; then
      log "clearing stuck 'running' tasks from DB"
      sqlite3 "$MANUL_DIR/manul.db" \
        "UPDATE processed_comments SET status='queued', processedAt=NULL WHERE status='running';"
    else
      log "WARNING: manul.db not found — skipped DB reset"
    fi
  fi
fi

# --- 4) proactive task health monitoring (NEW 2026-08-25) -----------------
# Detect tasks stuck in 'running' for longer than MAX_RUNNING_TIME
# and either reset them to 'queued' or mark as 'failed' based on attempt count
if [ -f "$MANUL_DIR/manul.db" ]; then
  # Find tasks stuck in 'running' state
  STUCK_TASKS="$(sqlite3 "$MANUL_DIR/manul.db" "
    SELECT commentId, repository, issueNumber, attempts, processedAt
    FROM processed_comments 
    WHERE status='running'
  " 2>/dev/null)"
  
  if [ -n "$STUCK_TASKS" ] && [ "$STUCK_TASKS" != "" ]; then
    while IFS='|' read -r comment_id repo issue_num attempts processed_at; do
      [ -z "$comment_id" ] && continue
      
      # Check if task has been running too long
      if [ -n "$processed_at" ]; then
        task_age_seconds=$(($(date +%s) - $(date -d "$processed_at" +%s 2>/dev/null || echo 0)))
        
        if [ "$task_age_seconds" -gt "$MAX_RUNNING_TIME" ]; then
          log "TASK HEALTH: $comment_id ($repo#$issue_num) stuck for ${task_age_seconds}s (max=${MAX_RUNNING_TIME}s), attempts=$attempts"
          
          # Check max attempts from config, default to 3
          MAX_ATTEMPTS="${CFG_MAX_ATTEMPTS:-3}"
          
          if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
            log "  → marking as FAILED (exceeded max attempts: $MAX_ATTEMPTS)"
            sqlite3 "$MANUL_DIR/manul.db" "
              UPDATE processed_comments 
              SET status='failed', attempts=attempts+1, processedAt=NULL 
              WHERE commentId='$comment_id';
            " 2>/dev/null
          else
            log "  → resetting to QUEUED for retry (attempt $((attempts+1))/$MAX_ATTEMPTS)"
            sqlite3 "$MANUL_DIR/manul.db" "
              UPDATE processed_comments 
              SET status='queued', processedAt=NULL 
              WHERE commentId='$comment_id';
            " 2>/dev/null
          fi
        fi
      fi
    done <<< "$STUCK_TASKS"
  fi
  
  # --- 5) alert on repeated failures ---------------------------------------
  # Check if any task has failed multiple times recently
  RECENT_FAILURES="$(sqlite3 "$MANUL_DIR/manul.db" "
    SELECT COUNT(*) FROM processed_comments 
    WHERE status='failed' 
    AND processedAt > datetime('now', '-1 hour')
  " 2>/dev/null)"
  
  if [ "$RECENT_FAILURES" -gt 3 ]; then
    log "ALERT: $RECENT_FAILURES failures in the last hour — possible systemic issue"
    # Could trigger webhook notification here if configured
    if [ -f "$CONFIG" ]; then
      ALERT_WEBHOOK="$(jq -r '.automation.alerts.failureWebhook // empty' "$CONFIG" 2>/dev/null)"
      if [ -n "$ALERT_WEBHOOK" ] && [ "$ALERT_WEBHOOK" != "null" ]; then
        curl -s -X POST "$ALERT_WEBHOOK" \
          -H 'Content-Type: application/json' \
          -d "{\"text\":\"⚠️ Manul alert: $RECENT_FAILURES failures in the last hour\"}" >>"$LOG" 2>&1 || true
      fi
    fi
  fi
fi

log "watchdog OK — daemon $(cat "$PID_FILE" 2>/dev/null) alive"
