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
# Logs are written to ~/.openclaw/manul/watchdog.log
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="$HOME/.openclaw/manul"
LOCK="$MANUL_DIR/lock"
PID_FILE="$MANUL_DIR/daemon.pid"
LOG="$MANUL_DIR/watchdog.log"
LOCK_TTL=1800  # 30 minutes — must match manul-daemon.sh LOCK_TTL_SECONDS

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

log "watchdog OK — daemon $(cat "$PID_FILE" 2>/dev/null) alive"
