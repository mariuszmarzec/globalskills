#!/bin/bash
# manul-status.sh - Display Manul automation status with enhanced observability
#
# Shows:
#   - Daemon running/stopped status with heartbeat state
#   - Current activity (what's being processed now)
#   - Last poll result (fire status, new/pending counts)
#   - Task counts by status (QUEUED/RUNNING/STUCK/FAILED)
#   - Recent task lifecycle events
#   - Watchdog health
#
# Usage: manul-status.sh [--json]
#
# Exit codes:
#   0 - Success
#   1 - Failure

# Configuration
MANUL_DIR="${MANUL_DIR:-${OPENCLAW_MANUL_DIR:-$HOME/.openclaw/manul}}"
DAEMON_LOG="$MANUL_DIR/daemon.log"
POLL_LOG="$MANUL_DIR/poll.log"
WATCHDOG_LOG="$MANUL_DIR/watchdog.log"
LIFECYCLE_LOG="$MANUL_DIR/lifecycle.log"
PID_FILE="$MANUL_DIR/daemon.pid"
LAST_POLL_FILE="$MANUL_DIR/last-poll"
CURRENT_ACTIVITY_FILE="$MANUL_DIR/current_activity"
DB="$MANUL_DIR/manul.db"
CONFIG="$MANUL_DIR/config.json"

# Colors for output (if available)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

JSON_OUTPUT=false
if [ "${1:-}" = "--json" ]; then
    JSON_OUTPUT=true
fi

# Helper: get current timestamp
now() {
    date '+%Y-%m-%d %H:%M:%S'
}

# JSON string escaper
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ============================================================================
# Collect Status Data
# ============================================================================

# Daemon status
get_daemon_status() {
    if [ -f "$PID_FILE" ] && [ -s "$PID_FILE" ]; then
        local pid
        pid="$(cat "$PID_FILE" | tr -d '[:space:]')"
        if kill -0 "$pid" 2>/dev/null; then
            echo "running|$pid"
            return 0
        fi
    fi
    echo "stopped|"
    return 1
}

# Current activity
get_current_activity() {
    if [ -f "$CURRENT_ACTIVITY_FILE" ] && [ -s "$CURRENT_ACTIVITY_FILE" ]; then
        cat "$CURRENT_ACTIVITY_FILE"
    else
        echo '{"task_id":"none","activity_type":"idle","display":"— No activity recorded","timestamp":""}'
    fi
}

# Last poll result
get_last_poll() {
    if [ -f "$LAST_POLL_FILE" ] && [ -s "$LAST_POLL_FILE" ]; then
        cat "$LAST_POLL_FILE"
    else
        echo '{"fire":false,"new":0,"pending":0,"timestamp":""}'
    fi
}

# Task counts
get_task_counts() {
    if [ ! -f "$DB" ]; then
        echo '{"queued":0,"running":0,"stuck":0,"failed":0,"completed":0}'
        return
    fi

    local queued running stuck failed completed
    queued="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued';" 2>/dev/null || echo 0)"
    running="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='running';" 2>/dev/null || echo 0)"
    stuck="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='running' AND heartbeatAt IS NOT NULL AND datetime(heartbeatAt) < datetime('now', '-600 seconds');" 2>/dev/null || echo 0)"
    failed="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='failed';" 2>/dev/null || echo 0)"
    completed="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='completed';" 2>/dev/null || echo 0)"

    printf '{"queued":%s,"running":%s,"stuck":%s,"failed":%s,"completed":%s}' \
        "$queued" "$running" "$stuck" "$failed" "$completed"
}

# Recent lifecycle events
get_recent_events() {
    if [ ! -f "$LIFECYCLE_LOG" ] || [ ! -s "$LIFECYCLE_LOG" ]; then
        echo '[]'
        return
    fi
    jq -c 'sort_by(.timestamp) | reverse | .[0:5]' "$LIFECYCLE_LOG" 2>/dev/null || echo '[]'
}

# Recent daemon log
get_recent_log() {
    if [ ! -f "$DAEMON_LOG" ] || [ ! -s "$DAEMON_LOG" ]; then
        echo '[]'
        return
    fi
    tail -5 "$DAEMON_LOG" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]'
}

# Watchdog status
get_watchdog_status() {
    local installed="false"
    local status_text="NOT installed"

    if crontab -l 2>/dev/null | grep -qF "$MANUL_DIR/watchdog.sh"; then
        installed="true"
        status_text="Installed (every 5 minutes)"
    fi

    # Get recent watchdog log entries
    local recent_log='[]'
    if [ -f "$WATCHDOG_LOG" ] && [ -s "$WATCHDOG_LOG" ]; then
        recent_log="$(tail -3 "$WATCHDOG_LOG" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')"
    fi

    printf '{"installed":%s,"status":"%s","recent_log":%s}' \
        "$installed" "$(json_escape "$status_text")" "$recent_log"
}

# Stuck tasks
get_stuck_tasks() {
    if [ ! -f "$DB" ]; then
        echo '[]'
        return
    fi

    local stuck_tasks
    stuck_tasks="$(sqlite3 "$DB" "SELECT commentId, repository, issueNumber, attempts, datetime(heartbeatAt) as last_heartbeat FROM processed_comments WHERE status='running' AND heartbeatAt IS NOT NULL AND datetime(heartbeatAt) < datetime('now', '-600 seconds') ORDER BY heartbeatAt ASC;" 2>/dev/null)"

    if [ -z "$stuck_tasks" ]; then
        echo '[]'
        return
    fi

    echo "$stuck_tasks" | while IFS='|' read -r cid repo issue attempts heartbeat; do
        printf '{"commentId":"%s","repository":"%s","issueNumber":%s,"attempts":%s,"last_heartbeat":"%s"}\n' \
            "$cid" "$repo" "$issue" "$attempts" "$heartbeat"
    done | jq -s '.' 2>/dev/null || echo '[]'
}

# ============================================================================
# Pretty-Print Functions (for terminal output)
# ============================================================================

print_daemon_status() {
    local status_info
    status_info="$(get_daemon_status)"
    local state pid
    state="$(echo "$status_info" | cut -d'|' -f1)"
    pid="$(echo "$status_info" | cut -d'|' -f2)"

    local status_text status_color
    case "$state" in
        running)
            status_text="RUNNING (pid $pid)"
            status_color="$GREEN"
            ;;
        *)
            status_text="STOPPED (no pid file${pid:+: stale pid=$pid})"
            status_color="$YELLOW"
            ;;
    esac

    printf '%b%s:%b %s%s\n' "$BOLD" "Daemon" "$NC" "${status_color}${status_text}${NC}"
}

print_current_activity() {
    local activity_json
    activity_json="$(get_current_activity)"
    local task_id activity_type display timestamp
    task_id="$(echo "$activity_json" | jq -r '.task_id // "none"' 2>/dev/null)"
    activity_type="$(echo "$activity_json" | jq -r '.activity_type // "unknown"' 2>/dev/null)"
    display="$(echo "$activity_json" | jq -r '.display // "unknown"' 2>/dev/null)"
    timestamp="$(echo "$activity_json" | jq -r '.timestamp // ""' 2>/dev/null)"

    local activity_color="$NC"
    case "$activity_type" in
        claimed) activity_color="$GREEN" ;;
        working) activity_color="$YELLOW" ;;
        completed) activity_color="$BLUE" ;;
        error)   activity_color="$RED" ;;
        idle)    activity_color="$CYAN" ;;
        none)    activity_color="$NC" ;;
        *)       activity_color="$YELLOW" ;;
    esac

    printf '%b  %sCurrent:%b %b%s%b\n' "$CYAN" "" "$NC" "$activity_color" "$display" "$NC"
    [ -n "$timestamp" ] && printf '     Timestamp: %s\n' "$timestamp"
}

print_last_poll() {
    local poll_json
    poll_json="$(get_last_poll)"
    local fire new_count pending timestamp
    fire="$(echo "$poll_json" | jq -r '.fire // false' 2>/dev/null)"
    new_count="$(echo "$poll_json" | jq -r '.new // 0' 2>/dev/null)"
    pending="$(echo "$poll_json" | jq -r '.pending // 0' 2>/dev/null)"
    timestamp="$(echo "$poll_json" | jq -r '.timestamp // ""' 2>/dev/null)"

    local fire_display fire_color
    if [ "$fire" = "true" ]; then
        fire_display="🔥 FIRED"
        fire_color="$RED"
    else
        fire_display="💤 No fire"
        fire_color="$CYAN"
    fi

    printf '%b  %sLast poll:%b %b%s%b | New: %b%s%b | Pending: %b%s%b' \
        "$CYAN" "" "$NC" "$fire_color" "$fire_display" "$NC" \
        "$GREEN" "$new_count" "$NC" "$YELLOW" "$pending" "$NC"
    [ -n "$timestamp" ] && printf ' | Time: %s' "$timestamp"
    printf '\n'
}

print_task_counts() {
    local counts_json
    counts_json="$(get_task_counts)"
    local queued running stuck failed completed
    queued="$(echo "$counts_json" | jq -r '.queued // 0')"
    running="$(echo "$counts_json" | jq -r '.running // 0')"
    stuck="$(echo "$counts_json" | jq -r '.stuck // 0')"
    failed="$(echo "$counts_json" | jq -r '.failed // 0')"
    completed="$(echo "$counts_json" | jq -r '.completed // 0')"

    printf '\n%b  %sTask Counts:%b\n' "$BOLD" "" "$NC"
    printf '     Queued:   %b%s%s\n' "$BLUE" "$queued" "$NC"
    printf '     Running:  %b%s%s\n' "$GREEN" "$running" "$NC"
    if [ "$stuck" -gt 0 ]; then
        printf '     Stuck:    %b%s%s ⚠️\n' "$RED" "$stuck" "$NC"
    else
        printf '     Stuck:    %s0%s\n' "$NC" "$NC"
    fi
    printf '     Failed:   %b%s%s\n' "$YELLOW" "$failed" "$NC"
    printf '     Completed:%b %s%s\n' "$NC" "$completed" "$NC"
}

print_recent_events() {
    local events_json
    events_json="$(get_recent_events)"

    if [ "$events_json" = "[]" ]; then
        printf '%b  %sRecent Events:%b No lifecycle events recorded\n' "$CYAN" "" "$NC"
        return
    fi

    printf '%b  %sRecent Events:%b (last 5)\n' "$CYAN" "" "$NC"
    echo "$events_json" | jq -r '.[] | "\( .event) | \( .task // "—") | \( .details // "—") | \( .timestamp)"' 2>/dev/null | \
    while IFS='|' read -r event task details timestamp; do
        local event_color="$NC"
        case "$event" in
            POLL)           event_color="$BLUE" ;;
            CLAIMED)        event_color="$GREEN" ;;
            WORKER_START)   event_color="$YELLOW" ;;
            WORKER_FINISH)  event_color="$YELLOW" ;;
            TASK_SUCCESS)   event_color="$GREEN" ;;
            TASK_FAILED)    event_color="$RED" ;;
            TASK_REQUEUED)  event_color="$CYAN" ;;
            TASK_ERROR)     event_color="$RED" ;;
            HEARTBEAT_START|HEARTBEAT_STOP) event_color="$CYAN" ;;
            LOCK_FAIL)      event_color="$RED" ;;
            NO_TASK)        event_color="$YELLOW" ;;
            DAEMON_START|DAEMON_STOP|LOOP_START) event_color="$BLUE" ;;
            *)              event_color="$NC" ;;
        esac
        printf '     %b%-16s%b | Task: %-10s | %s | %s\n' \
            "$event_color" "$event" "$NC" "$task" "$details" "$timestamp"
    done
}

print_watchdog_status() {
    local watchdog_json
    watchdog_json="$(get_watchdog_status)"
    local installed status_text
    installed="$(echo "$watchdog_json" | jq -r '.installed // false')"
    status_text="$(echo "$watchdog_json" | jq -r '.status // "unknown"')"

    local watchdog_color="$RED"
    [ "$installed" = "true" ] && watchdog_color="$GREEN"

    printf '\n%b  %sWatchdog:%b %b%s%b\n' \
        "$CYAN" "" "$NC" "$watchdog_color" "$status_text" "$NC"

    # Show recent watchdog log
    local recent_log
    recent_log="$(echo "$watchdog_json" | jq -r '.recent_log // [] | .[]')"
    if [ -n "$recent_log" ]; then
        printf '     %bRecent watchdog log:%b\n' "$YELLOW" "$NC"
        echo "$recent_log" | sed 's/^/       /'
    fi
}

print_stuck_tasks() {
    local stuck_json
    stuck_json="$(get_stuck_tasks)"

    local count
    count="$(echo "$stuck_json" | jq 'length')"

    if [ "$count" -eq 0 ]; then
        printf '%b  %sStuck Tasks:%b None detected\n' "$CYAN" "" "$NC"
        return
    fi

    printf '%b  %sStuck Tasks:%b\n' "$CYAN" "" "$NC"
    printf '     Found %b%s%s stuck task(s):\n' "$RED" "$count" "$NC"
    echo "$stuck_json" | jq -r '.[] | "       • \( .repository)@\(.commentId) (issue #\(.issueNumber), attempt \(.attempts)/?, last heartbeat: \(.last_heartbeat))"'
}

print_recent_log() {
    local log_json
    log_json="$(get_recent_log)"

    if [ "$log_json" = "[]" ]; then
        printf '%b  %sRecent Daemon Log:%b No log data available\n' "$CYAN" "" "$NC"
        return
    fi

    printf '%b  %sRecent Daemon Log:%b (last 5 lines)\n' "$CYAN" "" "$NC"
    echo "$log_json" | jq -r '.[]' | sed 's/^/     /'
}

# ============================================================================
# MAIN
# ============================================================================
if [ "$JSON_OUTPUT" = true ]; then
    # JSON mode: collect all data and output single JSON object
    local_daemon="$(get_daemon_status)"
    local_state="$(echo "$local_daemon" | cut -d'|' -f1)"
    local_pid="$(echo "$local_daemon" | cut -d'|' -f2)"

    local_activity="$(get_current_activity)"
    local_poll="$(get_last_poll)"
    local_counts="$(get_task_counts)"
    local_events="$(get_recent_events)"
    local_log="$(get_recent_log)"
    local_watchdog="$(get_watchdog_status)"
    local_stuck="$(get_stuck_tasks)"

    printf '{\n'
    printf '  "timestamp": "%s",\n' "$(now)"
    printf '  "manul_dir": "%s",\n' "$(json_escape "$MANUL_DIR")"
    printf '  "daemon": {"status": "%s", "pid": "%s"},\n' \
        "$local_state" "$(json_escape "$local_pid")"
    printf '  "activity": %s,\n' "$local_activity"
    printf '  "last_poll": %s,\n' "$local_poll"
    printf '  "task_counts": %s,\n' "$local_counts"
    printf '  "recent_events": %s,\n' "$local_events"
    printf '  "recent_log": %s,\n' "$local_log"
    printf '  "watchdog": %s,\n' "$local_watchdog"
    printf '  "stuck_tasks": %s\n' "$local_stuck"
    printf '}\n'
else
    # Pretty-print mode
    printf '\n'
    printf '%b========================================%b\n' "$BOLD" "$NC"
    printf '%b  Manul Automation Status Report%b\n' "$BOLD" "$NC"
    printf '%b========================================%b\n' "$BOLD" "$NC"
    printf '  Time: %s\n' "$(now)"
    printf '  Dir:  %s\n' "$MANUL_DIR"
    printf '%b----------------------------------------%b\n' "$BOLD" "$NC"

    print_daemon_status
    print_current_activity
    print_last_poll
    print_task_counts
    print_recent_events
    print_recent_log
    print_watchdog_status
    print_stuck_tasks

    printf '%b----------------------------------------%b\n' "$BOLD" "$NC"
    printf '%b  Status report completed.%b\n' "$GREEN" "$NC"
    printf '%b========================================%b\n' "$BOLD" "$NC"
    printf '\n'
fi

exit 0
