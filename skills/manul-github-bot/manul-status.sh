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

# If the configured MANUL_DIR has a stale PID (process not alive),
# fall back to the default location used by the daemon itself.
if [ -f "$PID_FILE" ]; then
    _stale_pid="$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$_stale_pid" ] && ! kill -0 "$_stale_pid" 2>/dev/null; then
        _default_dir="${OPENCLAW_MANUL_DIR:-$HOME/.openclaw/manul}"
        _actual_home="$HOME/.openclaw/manul"
        _found_dir=""
        
        # First try the explicit default
        if [ -f "$_default_dir/daemon.pid" ]; then
            _default_pid="$(cat "$_default_dir/daemon.pid" 2>/dev/null | tr -d '[:space:]')"
            if [ -n "$_default_pid" ] && kill -0 "$_default_pid" 2>/dev/null; then
                _found_dir="$_default_dir"
            fi
        fi
        
        # Then try the home location (in case OPENCLAW_MANUL_DIR differs)
        if [ -z "$_found_dir" ] && [ "$_actual_home" != "$_default_dir" ]; then
            if [ -f "$_actual_home/daemon.pid" ]; then
                _home_pid="$(cat "$_actual_home/daemon.pid" 2>/dev/null | tr -d '[:space:]')"
                if [ -n "$_home_pid" ] && kill -0 "$_home_pid" 2>/dev/null; then
                    _found_dir="$_actual_home"
                fi
            fi
        fi
        
        if [ -n "$_found_dir" ]; then
            MANUL_DIR="$_found_dir"
            DAEMON_LOG="$MANUL_DIR/daemon.log"
            POLL_LOG="$MANUL_DIR/poll.log"
            WATCHDOG_LOG="$MANUL_DIR/watchdog.log"
            LIFECYCLE_LOG="$MANUL_DIR/lifecycle.log"
            PID_FILE="$MANUL_DIR/daemon.pid"
            LAST_POLL_FILE="$MANUL_DIR/last-poll"
            CURRENT_ACTIVITY_FILE="$MANUL_DIR/current_activity"
            DB="$MANUL_DIR/manul.db"
            CONFIG="$MANUL_DIR/config.json"
        fi
    fi
fi
unset _stale_pid _default_dir _actual_home _found_dir _default_pid _home_pid 2>/dev/null

# Also check alternative locations for watchdog log
_alt_watchdog_log=""
if [ -f "$MANUL_DIR/watchdog.log" ]; then
    _alt_watchdog_log="$MANUL_DIR/watchdog.log"
fi
_other_dir="${MANUL_DIR/#$HOME/.\/mnt\/f\/ubuntu-workspace}"
if [ "$_other_dir" != "$MANUL_DIR" ] && [ -f "$_other_dir/watchdog.log" ]; then
    _alt_watchdog_log="$_other_dir/watchdog.log"
fi
unset _other_dir 2>/dev/null

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
        local line task_id activity_type timestamp
        line="$(cat "$CURRENT_ACTIVITY_FILE")"
        task_id="$(printf '%s' "$line" | cut -d'|' -f1)"
        activity_type="$(printf '%s' "$line" | cut -d'|' -f2)"
        timestamp="$(printf '%s' "$line" | cut -d'|' -f3)"
        jq -c -n \
            --arg task_id "${task_id:-none}" \
            --arg activity_type "${activity_type:-idle}" \
            --arg timestamp "${timestamp:-}" \
            '{task_id: $task_id, activity_type: $activity_type, display: (if $task_id == "none" then "— No activity recorded" else "\($task_id) [\($activity_type)] \($timestamp)" end), timestamp: $timestamp}'
    else
        echo '{"task_id":"none","activity_type":"idle","display":"— No activity recorded","timestamp":""}'
    fi
}

# Last poll result - handle malformed JSON gracefully
get_last_poll() {
    local default_poll='{"fire":false,"new":0,"pending":0,"timestamp":""}'
    
    if [ -f "$LAST_POLL_FILE" ] && [ -s "$LAST_POLL_FILE" ]; then
        local poll_content
        poll_content="$(cat "$LAST_POLL_FILE")"
        # Try to parse as JSON; if it fails, use defaults
        local parsed
        parsed="$(echo "$poll_content" | jq -c '.' 2>/dev/null)"
        if [ $? -eq 0 ] && [ -n "$parsed" ]; then
            echo "$parsed"
        else
            # Extract what we can from malformed JSON
            local ts fire new pending
            ts="$(echo "$poll_content" | grep -oP '"timestamp"\s*:\s*"[^"]*"' | sed 's/"timestamp"\s*:\s*"//;s/"//' || echo "")"
            fire="$(echo "$poll_content" | grep -oP '"fire"\s*:\s*\K[^,}]*' || echo "false")"
            new="$(echo "$poll_content" | grep -oP '"new"\s*:\s*\K[^,}]*' || echo "0")"
            pending="$(echo "$poll_content" | grep -oP '"pending"\s*:\s*\K[^,}]*' || echo "0")"
            
            # Validate extracted values
            [ -z "$fire" ] && fire="false"
            [ -z "$new" ] && new="0"
            [ -z "$pending" ] && pending="0"
            
            printf '{"fire":%s,"new":%s,"pending":%s,"timestamp":"%s"}' \
                "$fire" "$new" "$pending" "$ts"
        fi
    else
        echo "$default_poll"
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

# Recent lifecycle events - handle malformed entries
get_recent_events() {
    if [ ! -f "$LIFECYCLE_LOG" ] || [ ! -s "$LIFECYCLE_LOG" ]; then
        echo '[]'
        return
    fi
    tail -10 "$LIFECYCLE_LOG" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        # Skip pipe-only lines
        case "$line" in
            '|||'*|'') continue ;;
        esac
        
        # Parse bracketed format: [timestamp] EVENT details
        if [[ "$line" == \[* ]]; then
            local ts evt rest details
            ts="$(printf '%s' "$line" | sed -n 's/^\[\([^]]*\)\].*/\1/p')"
            rest="$(printf '%s' "$line" | sed 's/^\[[^]]*\] *//')"
            evt="$(printf '%s' "$rest" | awk '{print $1}')"
            details="$(printf '%s' "$rest" | sed "s/^${evt} *//")"
            
            # Extract key=value pairs from details
            local fire new pending
            fire="$(printf '%s' "$details" | grep -oP 'fire=\K[^ ]+' || echo "")"
            new="$(printf '%s' "$details" | grep -oP 'new=\K[^ ]+' || echo "")"
            pending="$(printf '%s' "$details" | grep -oP 'pending=\K[^ ]+' || echo "")"
            
            [ -z "$fire" ] && fire="?"
            [ -z "$new" ] && new="?"
            [ -z "$pending" ] && pending="?"
            
            printf '{"event":"%s","timestamp":"%s","details":"fire=%s new=%s pending=%s"}\n' \
                "$evt" "$ts" "$fire" "$new" "$pending"
        fi
    done | jq -sc 'sort_by(.timestamp) | reverse | .[0:5]' 2>/dev/null || echo '[]'
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
    
    # Check cron in both possible MANUL_DIR locations
    if crontab -l 2>/dev/null | grep -qF "watchdog.sh"; then
        installed="true"
        status_text="Installed (every 5 minutes)"
    fi

    # Get recent watchdog log entries - try multiple locations
    local recent_log='[]'
    local watchdog_log_to_use="$WATCHDOG_LOG"
    
    # If the primary location doesn't exist or is empty, try alternative
    if [ ! -f "$watchdog_log_to_use" ] || [ ! -s "$watchdog_log_to_use" ]; then
        if [ -n "$_alt_watchdog_log" ] && [ -f "$_alt_watchdog_log" ] && [ -s "$_alt_watchdog_log" ]; then
            watchdog_log_to_use="$_alt_watchdog_log"
        fi
    fi
    
    if [ -f "$watchdog_log_to_use" ] && [ -s "$watchdog_log_to_use" ]; then
        recent_log="$(tail -3 "$watchdog_log_to_use" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')"
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
            status_text="STOPPED"
            status_color="$RED"
            ;;
    esac

    printf '%b  %sDaemon:%b %s\n' "$status_color" "" "$NC" "$status_text"
}

print_current_activity() {
    local activity_info
    activity_info="$(get_current_activity)"
    local task_id activity_type timestamp display
    task_id="$(echo "$activity_info" | jq -r '.task_id' 2>/dev/null || echo 'none')"
    activity_type="$(echo "$activity_info" | jq -r '.activity_type' 2>/dev/null || echo 'idle')"
    timestamp="$(echo "$activity_info" | jq -r '.timestamp' 2>/dev/null || echo '')"
    display="$(echo "$activity_info" | jq -r '.display' 2>/dev/null || echo '— No activity recorded')"

    printf '%b  %sCurrent Activity:%b\n' "$CYAN" "" "$NC"
    if [ "$task_id" != "none" ]; then
        printf '     Task: %s\n' "$task_id"
        printf '     Type: %s\n' "$activity_type"
        printf '     Time: %s\n' "$timestamp"
    else
        printf '     %s\n' "$display"
    fi
}

print_last_poll() {
    local poll_info
    poll_info="$(get_last_poll)"
    local fire new pending timestamp
    fire="$(echo "$poll_info" | jq -r 'if .fire == null or .fire == "" then "unknown" else (.fire | tostring) end' 2>/dev/null || echo "unknown")"
    new="$(echo "$poll_info" | jq -r '.new // 0' 2>/dev/null || echo 0)"
    pending="$(echo "$poll_info" | jq -r '.pending // 0' 2>/dev/null || echo 0)"
    timestamp="$(echo "$poll_info" | jq -r '.timestamp // "unknown"' 2>/dev/null || echo "unknown")"

    printf '%b  %sLast Poll:%b\n' "$YELLOW" "" "$NC"
    printf '     Fire: %s\n' "$fire"
    printf '     New: %s\n' "$new"
    printf '     Pending: %s\n' "$pending"
    printf '     Time: %s\n' "$timestamp"
}

print_task_counts() {
    local counts_info
    counts_info="$(get_task_counts)"
    local queued running stuck failed completed
    queued="$(echo "$counts_info" | jq -r '.queued // 0' 2>/dev/null || echo 0)"
    running="$(echo "$counts_info" | jq -r '.running // 0' 2>/dev/null || echo 0)"
    stuck="$(echo "$counts_info" | jq -r '.stuck // 0' 2>/dev/null || echo 0)"
    failed="$(echo "$counts_info" | jq -r '.failed // 0' 2>/dev/null || echo 0)"
    completed="$(echo "$counts_info" | jq -r '.completed // 0' 2>/dev/null || echo 0)"

    printf '%b  %sTask Counts:%b\n' "$BLUE" "" "$NC"
    printf '     QUEUED: %s\n' "$queued"
    printf '     RUNNING: %s\n' "$running"
    printf '     STUCK: %s\n' "$stuck"
    printf '     FAILED: %s\n' "$failed"
    printf '     COMPLETED: %s\n' "$completed"
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

print_watchdog_status() {
    local watchdog_json
    watchdog_json="$(get_watchdog_status)"
    local installed status_text
    installed="$(echo "$watchdog_json" | jq -r '.installed // false')"
    status_text="$(echo "$watchdog_json" | jq -r '.status // "unknown"')"

    printf '%b  %sWatchdog:%b %s\n' "$GREEN" "" "$NC" "$status_text"
}

print_stuck_tasks() {
    local stuck_json
    stuck_json="$(get_stuck_tasks)"
    local count
    count="$(echo "$stuck_json" | jq -r '. | length' 2>/dev/null || echo 0)"

    if [ "$count" -eq 0 ]; then
        printf '%b  %sStuck Tasks:%b None detected\n' "$CYAN" "" "$NC"
        return
    fi

    printf '%b  %sStuck Tasks:%b\n' "$CYAN" "" "$NC"
    printf '     Found %b%s%s stuck task(s):\n' "$RED" "$count" "$NC"
    echo "$stuck_json" | jq -r '.[] | "       • \( .repository)@\(.commentId) (issue #\(.issueNumber), attempt \(.attempts)/?, last heartbeat: \(.last_heartbeat))"'
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
