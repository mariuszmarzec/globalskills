#!/bin/bash
# manul-status.sh - Display Manul automation status
#
# Shows the status of all Manul components including the daemon,
# recent logs, and stuck tasks.
#
# Usage: manul-status.sh
#
# Exit codes:
#   0 - Success
#   1 - Failure

# Configuration
MANUL_DIR="${MANUL_DIR:-$OPENCLAW_MANUL_DIR:-$HOME/.openclaw/manul}"
DAEMON_LOG="$MANUL_DIR/daemon.log"
WATCHDOG_LOG="$MANUL_DIR/watchdog.log"

# Colors for output (if available)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

function status_daemon() {
    local pid_file="$MANUL_DIR/daemon.pid"

    if [ -f "$pid_file" ] && [ -s "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" | tr -d ' ')

        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${GREEN}Daemon:${NC} RUNNING (pid: $pid)"
            return 0
        else
            echo -e "${RED}Daemon:${NC} STOPPED (stale pid file: $pid)"
            return 1
        fi
    else
        echo -e "${YELLOW}Daemon:${NC} STOPPED (no pid file)"
        return 1
    fi
}

function show_recent_logs() {
    local log_file="$1"
    local log_name="$2"
    local lines=5

    if [ -f "$log_file" ] && [ -s "$log_file" ]; then
        echo -e "\n${YELLOW}Recent ${log_name} (last ${lines} lines):${NC}"
        tail -"$lines" "$log_file" | sed 's/^/   /' || true
    else
        echo -e "\n${YELLOW}Recent ${log_name}:${NC} No log data available"
    fi
}

function show_stuck_tasks() {
    local recovery_script="$MANUL_DIR/task-recovery.sh"

    echo -e "\n${YELLOW}Stuck Tasks Analysis:${NC}"

    if [ -x "$recovery_script" ]; then
        local stuck_count
        stuck_count=$( "$recovery_script" --list-stuck | wc -l || true )

        if [ "$stuck_count" -gt 0 ]; then
            echo -e "   Found ${RED}$stuck_count${NC} stuck task(s):"
            "$recovery_script" --list-stuck | sed 's/^/     /' || true
        else
            echo -e "   No stuck tasks found."
        fi
    else
        echo -e "   Task recovery script not found: $recovery_script"
    fi
}

function show_watchdog_status() {
    echo -e "\n${YELLOW}Watchdog (automatic recovery):${NC}"
    if crontab -l 2>/dev/null | grep -qF "$MANUL_DIR/watchdog.sh"; then
        echo -e "   ${GREEN}installed${NC} (every 5 minutes)"
    else
        echo -e "   ${RED}NOT installed${NC}"
    fi
    if [ -f "$WATCHDOG_LOG" ] && [ -s "$WATCHDOG_LOG" ]; then
        echo -e "\n${YELLOW}Recent Watchdog Log (last 5 lines):${NC}"
        tail -5 "$WATCHDOG_LOG" | sed 's/^/   /' || true
    fi
}

# --- MAIN ---
echo "=== Manul Automation Status ==="

# Daemon status
status_daemon

# Watchdog status
show_watchdog_status

# Recent logs
show_recent_logs "$DAEMON_LOG" "Daemon Log"

# Stuck tasks
show_stuck_tasks

echo
echo -e "${GREEN}Status report completed.${NC}"
exit 0
