#!/bin/bash
# task-recovery.sh — Manual recovery for stuck tasks
#
# This script provides manual intervention capabilities.
#
# Usage: task-recovery.sh [options]
#   --list-stuck      List all tasks stuck in 'running'
#   --reset <id>      Reset a specific task commentId to 'queued'
#   --mark-failed <id> Mark a specific task commentId as 'failed'
#   --reset-all       Reset all stuck tasks (dangerous - confirm)
#   --health-check    Run comprehensive health check

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
# DB on native ext4 (NOT on 9p /mnt/f)
DB="${MANUL_DIR}/manul.db"
LOG="${MANUL_DIR}/task-recovery.log"
CFG_RETRY_DELAY="$(jq -r '.retryConfig.delaySeconds // 60' "$CONFIG" 2>/dev/null || echo "60")"
RETRY_DELAY_SECONDS="${MANUL_RETRY_DELAY_SECONDS:-${CFG_RETRY_DELAY:-60}}"

log() { echo "[$(date -Is)] $*"; }

list_stuck_tasks() {
    log "=== LISTING STUCK TASKS ==="
    if [ ! -f "$DB" ]; then
        log "ERROR: manul.db not found"
        return 1
    fi
    sqlite3 "$DB" "
        SELECT commentId, repository, issueNumber, status, attempts, heartbeatAt, workerPid
        FROM processed_comments
        WHERE status='running'
        ORDER BY createdAt DESC;
    " 2>/dev/null
}

reset_task() {
    local comment_id="$1"
    log "Resetting task $comment_id to queued"
    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds')
        WHERE commentId='$comment_id' AND status='running';
    " 2>/dev/null
}

mark_task_failed() {
    local comment_id="$1"
    log "Marking task $comment_id as failed"
    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='failed', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=NULL
        WHERE commentId='$comment_id' AND status='running';
    " 2>/dev/null
}

retry_failed_task() {
    local comment_id="$1"
    log "Retrying failed task $comment_id from scratch"
    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='queued', attempts=0, processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now')
        WHERE commentId='$comment_id' AND status='failed';
    " 2>/dev/null
}

retry_all_failed_tasks() {
    log "WARNING: Retrying ALL failed tasks from scratch (DANGEROUS)"
    read -p "Are you sure? (yes/no): " -r confirm
    if [ "$confirm" != "yes" ]; then
        log "Aborted"
        return
    fi
    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='queued', attempts=0, processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now')
        WHERE status='failed';
    " 2>/dev/null
    log "All failed tasks requeued from scratch"
}

reset_all_tasks() {
    local status_filter="${1:-running}"
    case "$status_filter" in
        running|failed) ;;
        *)
            echo "Error: --reset-all supports only running or failed" >&2
            return 1
            ;;
    esac

    log "WARNING: Resetting ALL $status_filter tasks to queued (DANGEROUS)"
    read -p "Are you sure? (yes/no): " -r confirm
    if [ "$confirm" != "yes" ]; then
        log "Aborted"
        return
    fi

    if [ "$status_filter" = "failed" ]; then
        sqlite3 "$DB" "UPDATE processed_comments SET status='queued', attempts=0, processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now') WHERE status='failed';" 2>/dev/null
    else
        sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE status='running';" 2>/dev/null
    fi

    log "All $status_filter tasks reset"
}

health_check() {
    log "=== HEALTH CHECK ==="
    if [ ! -f "$DB" ]; then
        log "ERROR: manul.db not found"
        return 1
    fi
    
    local total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;" 2>/dev/null || echo 0)
    local queued=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued';" 2>/dev/null || echo 0)
    local running=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='running';" 2>/dev/null || echo 0)
    local done=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='done';" 2>/dev/null || echo 0)
    local failed=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='failed';" 2>/dev/null || echo 0)
    
    log "Total tasks: $total"
    log "Queued: $queued"
    log "Running: $running"
    log "Done: $done"
    log "Failed: $failed"
    
    if [ "$running" -gt 0 ]; then
        log "WARNING: $running tasks are still running"
        list_stuck_tasks
    fi
}

# Parse arguments
case "${1:-}" in
    --list-stuck)
        list_stuck_tasks
        ;;
    --reset)
        shift
        reset_task "$1"
        ;;
    --mark-failed)
        shift
        mark_task_failed "$1"
        ;;
    --reset-all)
        reset_all_tasks "running"
        ;;
    --reset-all=*)
        reset_all_tasks "${1#--reset-all=}"
        ;;
    --retry)
        shift
        if [ -z "${1:-}" ]; then
            echo "Error: --retry requires a task id" >&2
            exit 1
        fi
        retry_failed_task "$1"
        ;;
    --health-check)
        health_check
        ;;
    *)
        echo "Usage: $0 [--list-stuck|--reset <id>|--mark-failed <id>|--reset-all[=running|failed]|--retry <id>|--health-check]"
        exit 1
        ;;
esac
