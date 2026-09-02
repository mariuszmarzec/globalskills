#!/bin/bash
# watchdog.sh — ONLY automatic recovery mechanism
#
# Run from cron every 5 minutes:
#   */5 * * * * $MANUL_DIR/watchdog.sh
#
# Responsibilities:
#   1. Start the daemon if it is not running.
#   2. Detect a stale lock file (age >= LOCK_TTL) and remove it (WITHOUT resetting tasks).
#   3. Recover tasks based on stale heartbeat/lease ONLY.

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="${MANUL_DIR}/config.json"
LOCK="$MANUL_DIR/lock"
PID_FILE="$MANUL_DIR/daemon.pid"
LOG="$MANUL_DIR/watchdog.log"
DB="$MANUL_DIR/manul.db"
LOCK_TTL="${MANUL_LOCK_TTL_SECONDS:-1800}"  # 30 minutes
MAX_ATTEMPTS="${MANUL_MAX_ATTEMPTS:-3}"

# Load config overrides
if [ -f "$CONFIG" ]; then
    CFG_MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // empty' "$CONFIG" 2>/dev/null)"
    [ -n "$CFG_MAX_ATTEMPTS" ] && MAX_ATTEMPTS="$CFG_MAX_ATTEMPTS"
    CFG_LOCK_TTL="$(jq -r '.automation.lockTtl // empty' "$CONFIG" 2>/dev/null)"
    [ -n "$CFG_LOCK_TTL" ] && LOCK_TTL="$CFG_LOCK_TTL"
    CFG_HEARTBEAT_TIMEOUT="$(jq -r '.automation.heartbeatTimeout // empty' "$CONFIG" 2>/dev/null)"
    CFG_LEASE_TIMEOUT="$(jq -r '.automation.leaseTimeout // empty' "$CONFIG" 2>/dev/null)"
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
        # NO DB reset on stale lock - only heartbeat-based recovery
    fi
fi

# --- 3) heartbeat-based task recovery -------------------------------------
if [ -f "$DB" ]; then
    # Find tasks with stale heartbeat
    STUCK_TASKS="$(sqlite3 "$DB" "
        SELECT commentId, repository, issueNumber, attempts, heartbeatAt, leaseExpiresAt
        FROM processed_comments
        WHERE status='running'
        AND (
            heartbeatAt < datetime('now', '-${CFG_HEARTBEAT_TIMEOUT:-900} seconds') OR
            leaseExpiresAt < datetime('now')
        )
    " 2>/dev/null)"

    if [ -n "$STUCK_TASKS" ] && [ "$STUCK_TASKS" != "" ]; then
        while IFS='|' read -r comment_id repo issue_num attempts heartbeat_at lease_at; do
            [ -z "$comment_id" ] && continue
            log "RECOVERY: $comment_id ($repo#$issue_num) stuck (heartbeat: $heartbeat_at, lease: $lease_at), attempts=$attempts"
            
            # Check if we've exceeded max attempts
            if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
                log "  → marking as FAILED (exceeded max attempts: $MAX_ATTEMPTS)"
                sqlite3 "$DB" "
                    UPDATE processed_comments
                    SET status='failed', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL
                    WHERE commentId='$comment_id';
                " 2>/dev/null
            else
                log "  → resetting to QUEUED for retry (no attempt increment)"
                sqlite3 "$DB" "
                    UPDATE processed_comments
                    SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL
                    WHERE commentId='$comment_id';
                " 2>/dev/null
            fi
        done <<< "$STUCK_TASKS"
    fi
fi

log "watchdog completed — daemon $(cat "$PID_FILE" 2>/dev/null) alive"
