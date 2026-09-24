#!/bin/bash
# watchdog.sh — ONLY automatic recovery mechanism
#
# Run from cron every 5 minutes:
#   */5 * * * * $MANUL_DIR/watchdog.sh
#
# Responsibilities:
#   1. Start the daemon if it is not running.
#   2. Detect a stale lock file (age >= LOCK_TTL) and remove it (WITHOUT resetting tasks).
#   3. Recover tasks based on stale heartbeat/lease ONLY, respecting worker ownership.

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
CONFIG="${MANUL_DIR}/config.json"
LOCK="$MANUL_DIR/lock"
PID_FILE="${MANUL_DIR}/daemon.pid"
LOG="$MANUL_DIR/watchdog.log"
# DB on native ext4 (NOT on 9p /mnt/f)
DB="${MANUL_DIR}/manul.db"
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

HEARTBEAT_TIMEOUT="${CFG_HEARTBEAT_TIMEOUT:-900}"
CFG_RETRY_DELAY="$(jq -r '.retryConfig.delaySeconds // 60' "$CONFIG" 2>/dev/null || echo "60")"
RETRY_DELAY_SECONDS="${MANUL_RETRY_DELAY_SECONDS:-${CFG_RETRY_DELAY:-60}}"

log() { echo "[$(date -Is)] $*" >> "$LOG"; }

# --- .enabled gate --------------------------------------------------------
# The .enabled marker is the lifecycle contract between intentional start/stop
# and the watchdog. It is created by install-manul.sh (fresh install), the `manul`
# alias, and start-manul-automation.sh start; it is removed by
# start-manul-automation.sh stop and manul-daemon.sh stop.
#
# The watchdog ONLY performs recovery when .enabled is present. This is what
# prevents an endless restart loop: if the daemon dies, the watchdog restarts
# it — but it never re-enables automation. A human (or the `manul` alias) must
# intentionally re-enable it. Without this gate, a crash during boot would leave
# the watchdog spinning forever, and a machine that was intentionally stopped
# would silently come back to life.
if [ ! -f "$MANUL_DIR/.enabled" ]; then
    log "Manul not intentionally enabled (no .enabled marker) — skipping recovery"
    exit 0
fi

# --- 1) daemon liveness ----------------------------------------------------
# Reclaim stale workspaces before attempting daemon startup. Without this,
# a dead worker can leave a BUSY workspace forever and make daemon start fail
# with "insufficient workspaces for concurrency".
if [ -f "$DB" ] && [ -f "$MANUL_DIR/workspace-manager.sh" ]; then
    if bash -n "$MANUL_DIR/workspace-manager.sh" 2>/dev/null && source "$MANUL_DIR/workspace-manager.sh"; then
        if ! workspace_cleanup_stale 3600; then
            log "workspace stale cleanup failed"
        fi
    else
        log "ERROR: invalid workspace manager: $MANUL_DIR/workspace-manager.sh"
    fi
fi

if ! [ -f "$PID_FILE" ] || ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    log "daemon not running (no pid / pid not alive) → starting"
    rm -f "$PID_FILE"  # Clear stale PID file before starting
    "$MANUL_DIR/manul-daemon.sh" start >>"$LOG" 2>&1
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
    # Migrate legacy databases before recovery.
    if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|claimToken|'; then
        sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN claimToken TEXT;" 2>>"$LOG"
        log "migration: added claimToken column"
    fi
    # Find tasks with stale heartbeat or expired lease
    # CRITICAL: Only recover tasks where the worker is dead (not alive)
    # This prevents stealing from live workers
    STUCK_TASKS="$(sqlite3 "$DB" "
        SELECT commentId, repository, issueNumber, attempts, heartbeatAt, leaseExpiresAt, workerPid, claimToken
        FROM processed_comments
        WHERE status='running'
        AND (
            heartbeatAt IS NULL OR
            heartbeatAt < datetime('now', '-${HEARTBEAT_TIMEOUT} seconds') OR
            leaseExpiresAt IS NULL OR
            leaseExpiresAt < datetime('now')
        )
    " 2>/dev/null)"

    if [ -n "$STUCK_TASKS" ] && [ "$STUCK_TASKS" != "" ]; then
        while IFS='|' read -r comment_id repo issue_num attempts heartbeat_at lease_at worker_pid claim_token; do
            [ -z "$comment_id" ] && continue

            # workerPid identifies the long-lived worker loop, not one task.
            worker_alive=0
            if [ -n "$worker_pid" ] && [ "$worker_pid" != "0" ] && kill -0 "$worker_pid" 2>/dev/null; then
                worker_alive=1
            fi
            log "RECOVERY: $comment_id ($repo#$issue_num) stale (worker=$worker_pid alive=$worker_alive heartbeat=$heartbeat_at lease=$lease_at attempts=$attempts)"

            ownership_clause=""
            if [ -n "$claim_token" ]; then
                safe_claim_token="$(printf '%s' "$claim_token" | sed "s/'/''/g")"
                ownership_clause="AND claimToken='$safe_claim_token'"
            else
                ownership_clause="AND claimToken IS NULL"
            fi

            if [ "${attempts:-0}" -ge "$MAX_ATTEMPTS" ]; then
                log "  → marking as FAILED (max attempts: $MAX_ATTEMPTS)"
                sqlite3 "$DB" "
                    UPDATE processed_comments
                    SET status='failed', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=NULL
                    WHERE commentId='$comment_id' AND status='running' $ownership_clause;
                " 2>/dev/null
            else
                log "  → resetting to QUEUED for retry (preserving attempts=$attempts, no increment)"
                sqlite3 "$DB" "
                    UPDATE processed_comments
                    SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds')
                    WHERE commentId='$comment_id' AND status='running' $ownership_clause;
                " 2>/dev/null
            fi
        done <<< "$STUCK_TASKS"
    fi
fi

log "watchdog completed — daemon $(cat "$PID_FILE" 2>/dev/null) alive"