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
DB="${MANUL_DIR}/manul.db"
LOG="${MANUL_DIR}/task-recovery.log"

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
        SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL
        WHERE commentId='$comment_id' AND status='running';
    " 2>/dev/null
}

mark_task_failed() {
    local comment_id="$1"
    log "Marking task $comment_id as failed"
    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='failed', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL
        WHERE commentId='$comment_id' AND status='running';
    " 2>/dev/null
}

reset_all_tasks() {
    log "WARNING: Resetting ALL running tasks to queued (DANGEROUS)"
    read -p "Are you sure? (yes/no): " -r confirm
    if [ "$confirm" != "yes" ]; then
        log "Aborted"
        return
    fi
    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL
        WHERE status='running';
    " 2>/dev/null
    log "All running tasks reset"
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
        reset_all_tasks
        ;;
    --health-check)
        health_check
        ;;
    *)
        echo "Usage: $0 [--list-stuck|--reset <id>|--mark-failed <id>|--reset-all|--health-check]"
        exit 1
        ;;
esac
