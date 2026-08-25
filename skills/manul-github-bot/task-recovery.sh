#!/bin/bash
# task-recovery.sh — Focused recovery for stuck tasks
#
# This script provides targeted actions for tasks that appear stuck,
# especially when orchestrator failures leave tasks in 'running' state
# without progress.
#
# Usage: task-recovery.sh [options]
#   --list-stuck      List all tasks stuck in 'running'
#   --reset <id>      Reset a specific task commentId to 'queued'
#   --mark-failed <id> Mark a specific task commentId as 'failed'
#   --reset-all       Reset all stuck tasks (dangerous - confirm)
#   --health-check    Run a comprehensive health check
#
# The main problem this addresses: When orchestrator crashes
# (e.g., session lock/compaction error), the task stays in 'running'
# state forever, blocking the queue from processing other tasks.
#
# History:
#   2026-08-25 — Initial version with health monitoring and auto-recover
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="${MANUL_DIR}/config.json"
DB="${MANUL_DIR}/manul.db"

log() { echo "[$(date -Is)] $*"; }

# Load configuration
get_config() {
    if [ ! -f "$CONFIG" ]; then
        return
    fi
    jq -r "$1" "$CONFIG" 2>/dev/null || echo ""
}

# Get max running time from config or default
MAX_RUNNING_TIME=$(get_config '.automation.maxTaskRunningTime // 1800')
MAX_ATTEMPTS=$(get_config '.automation.maxAttemptsBeforeFail // 3')

list_stuck_tasks() {
    log "=== LISTING STUCK TASKS ==="

    if [ ! -f "$DB" ]; then
        log "ERROR: manul.db not found"
        return 1
    fi

    # Build datetime expression — avoids variable-expansion issues in SQL strings
    local max_time_secs="$MAX_RUNNING_TIME"
    local datetime_expr
    datetime_expr=$(printf "datetime('now', '-%d seconds')" "$max_time_secs")

    sqlite3 "$DB" "
        SELECT
            commentId,
            repository,
            issueNumber,
            status,
            attempts,
            createdAt,
            processedAt,
            CASE
                WHEN processedAt IS NULL THEN 'No processedAt (likely crashed)'
                WHEN status='running' AND processedAt < $datetime_expr
                THEN 'Running for >15 minutes'
                ELSE 'Other'
            END as reason
        FROM processed_comments
        WHERE status='running'
        ORDER BY processedAt;
    " | awk 'NR>1 {print "  " $1 " | " $2 "#" $3 " | " $4 " | attempts=" $5 " | created=" $6 " | processed=" $7 " | reason=" $8}'

    log "=== END LISTING ==="
}

reset_task() {
    local comment_id="$1"
    local repo="$2"
    local issue_num="$3"

    if [ -z "$comment_id" ]; then
        log "ERROR: commentId required for reset"
        return 1
    fi

    log "Resetting task: $comment_id ($repo#$issue_num)"

    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='queued', processedAt=NULL
        WHERE commentId='$comment_id';
    " 2>/dev/null

    local affected
    affected=$(sqlite3 "$DB" "SELECT changes() FROM processed_comments WHERE commentId='$comment_id';" 2>/dev/null || echo "0")

    if [ "$affected" -gt 0 ]; then
        log "SUCCESS: Task reset to queued (will be retried)"

        # Post recovery comment on GitHub
        if [ -n "$repo" ] && [ -n "$issue_num" ] && [ -f "$MANUL_DIR/feedback.sh" ] && [ -x "$MANUL_DIR/feedback.sh" ]; then
            local recovery_msg="⚠️ Task recovered from crash: This task was stuck in 'running' state due to orchestrator failure. I've reset it to 'queued' for retry."
            "$MANUL_DIR/feedback.sh" "$repo" "$issue_num" "$recovery_msg" >>"$MANUL_DIR/watchdog.log" 2>&1 || true
        fi

        return 0
    else
        log "ERROR: Failed to reset task $comment_id"
        return 1
    fi
}

mark_task_failed() {
    local comment_id="$1"
    local attempts="$2"

    if [ -z "$comment_id" ]; then
        log "ERROR: commentId required for mark-failed"
        return 1
    fi

    local current_attempts="${attempts:-0}"
    local new_attempts=$((current_attempts + 1))

    log "Marking task as failed: $comment_id (attempts $current_attempts → $new_attempts)"

    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='failed', attempts=$new_attempts, processedAt=NULL
        WHERE commentId='$comment_id';
    " 2>/dev/null

    local affected
    affected=$(sqlite3 "$DB" "SELECT changes() FROM processed_comments WHERE commentId='$comment_id';" 2>/dev/null || echo "0")

    if [ "$affected" -gt 0 ]; then
        log "SUCCESS: Task marked as failed (will not be retried)"

        # Send failure webhook if configured
        local failure_webhook
        failure_webhook=$(get_config '.automation.alerts.failureWebhook // empty')
        if [ -n "$failure_webhook" ] && [ "$failure_webhook" != "null" ]; then
            curl -s -X POST "$failure_webhook" \
                -H 'Content-Type: application/json' \
                -d "{\"text\":\"🚨 Manul Task Failure: $comment_id marked as failed after $new_attempts attempt(s)\"}" >>"$MANUL_DIR/watchdog.log" 2>&1 || true
        fi

        return 0
    else
        log "ERROR: Failed to mark task $comment_id as failed"
        return 1
    fi
}

health_check() {
    log "=== COMPREHENSIVE HEALTH CHECK ==="

    if [ ! -f "$DB" ]; then
        log "ERROR: manul.db not found"
        return 1
    fi

    local total running stuck reset_failed auto_failed
    total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;" 2>/dev/null || echo "0")
    running=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='running';" 2>/dev/null || echo "0")
    reset_failed=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='running' AND attempts >= $MAX_ATTEMPTS;" 2>/dev/null || echo "0")
    auto_failed=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='failed';" 2>/dev/null || echo "0")

    log "Summary: total=$total, running=$running, reset_failed=$reset_failed, auto_failed=$auto_failed"

    if [ "$running" -gt 0 ]; then
        log "Running Tasks (first 10):"

        local max_time_secs="$MAX_RUNNING_TIME"
        local datetime_expr
        datetime_expr=$(printf "datetime('now', '-%d seconds')" "$max_time_secs")

        sqlite3 "$DB" "
            SELECT
                commentId,
                repository,
                issueNumber,
                attempts,
                createdAt,
                processedAt,
                CASE
                    WHEN processedAt IS NULL THEN 'Crash (no timestamp)'
                    WHEN processedAt < $datetime_expr
                    THEN 'Stuck (>15 min)'
                    ELSE 'Normal'
                END as status_detail
            FROM processed_comments
            WHERE status='running'
            ORDER BY processedAt
            LIMIT 10;
        " | awk 'NR>1 {
            comment=$1; repo=$2; issue=$3; attempts=$4; created=$5; processed=$6; detail=$7;
            printf "  %s | %s#%s | attempts=%s | started=%s | detail=%s\n", comment, repo, issue, attempts, created, detail;
        }'
    fi

    # Check for critical issues
    local critical_issues=0

    if [ "$running" -gt 0 ]; then
        log "Critical Issues Found:"

        local max_time_secs="$MAX_RUNNING_TIME"
        local datetime_expr
        datetime_expr=$(printf "datetime('now', '-%d seconds')" "$max_time_secs")

        sqlite3 "$DB" "
            SELECT
                commentId,
                repository,
                issueNumber,
                attempts,
                processedAt,
                CASE
                    WHEN processedAt < $datetime_expr THEN 'STUCK'
                    WHEN attempts >= $MAX_ATTEMPTS THEN 'MAX_ATTEMPTS_REACHED'
                    WHEN processedAt IS NULL THEN 'CRASHED'
                    ELSE 'MONITORING'
                END as issue_type
            FROM processed_comments
            WHERE status='running'
            AND (processedAt < $datetime_expr
                 OR attempts >= $MAX_ATTEMPTS
                 OR processedAt IS NULL);
        " | awk 'NR>1 {
            critical_issues++;
            comment=$1; repo=$2; issue=$3; attempts=$4; processed=$6; issue_type=$7;
            printf "  %s | %s#%s | %s | action=%s\n", comment, repo, issue, attempts, issue_type;
        }'
    fi

    log "Health check complete. Critical issues: $critical_issues"
    return 0
}

# --- MAIN ---
if [ $# -lt 1 ]; then
    echo "Usage: $0 [--list-stuck | --reset <commentId> | --mark-failed <commentId> | --reset-all | --health-check]"
    echo "  --list-stuck        List all tasks stuck in 'running' state"
    echo "  --reset <id>        Reset a specific task to 'queued'"
    echo "  --mark-failed <id>  Mark a specific task as 'failed'"
    echo "  --reset-all         Reset ALL running tasks (requires confirmation)"
    echo "  --health-check      Run comprehensive health check with recommendations"
    exit 1
fi

case "$1" in
    --list-stuck)
        list_stuck_tasks
        ;;
    --reset-all)
        echo "WARNING: This will reset ALL running tasks back to queued state"
        echo "Are you sure? (yes/no)"
        read -r confirmation
        if [ "$confirmation" = "yes" ]; then
            log "Resetting all running tasks to queued"
            sqlite3 "$DB" "
                UPDATE processed_comments
                SET status='queued', processedAt=NULL
                WHERE status='running';
            " 2>/dev/null
            log "All running tasks reset to queued"
        else
            log "Reset cancelled by user"
        fi
        ;;
    --health-check)
        health_check
        ;;
    --reset)
        if [ -z "$2" ]; then
            echo "ERROR: commentId required for --reset"
            exit 1
        fi

        local comment_id="$2"
        local repo issue_num
        if echo "$comment_id" | grep -q "^issue:"; then
            local details
            details=$(sqlite3 "$DB" "
                SELECT repository, issueNumber
                FROM processed_comments
                WHERE commentId='$comment_id';
            " 2>/dev/null)
            if [ -n "$details" ]; then
                repo=$(echo "$details" | cut -d'|' -f1)
                issue_num=$(echo "$details" | cut -d'|' -f2)
            fi
        fi

        reset_task "$comment_id" "$repo" "$issue_num"
        ;;
    --mark-failed)
        if [ -z "$2" ]; then
            echo "ERROR: commentId required for --mark-failed"
            exit 1
        fi

        local current_attempts=0
        if echo "$2" | grep -q "^issue:"; then
            current_attempts=$(sqlite3 "$DB" "
                SELECT attempts FROM processed_comments
                WHERE commentId='$2';
            " 2>/dev/null || echo "0")
        fi

        mark_task_failed "$2" "$current_attempts"
        ;;
    *)
        echo "ERROR: Unknown command: $1"
        exit 1
        ;;
esac

log "Task recovery operations completed"
exit 0