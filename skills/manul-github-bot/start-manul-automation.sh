#!/bin/bash
# start-manul-automation.sh - Enhanced Manul automation startup script
#
# This script starts all components of the manul GitHub bot with
# enhanced automation features for better resilience and monitoring.
#
# Features included:
# - Enhanced watchdog with proactive task health monitoring
# - Task health check service that detects and recovers stuck tasks
# - Task recovery tools for manual intervention
# - Updated configuration with automation settings
#
# Usage: start-manul-automation.sh [options]
#   start         Start all components (default)
#   stop          Stop all components
#   status        Show status of all components
#   restart       Restart all components
#   install       Install and configure everything
#
#
# History:
#   2026-08-25 — Initial version with enhanced automation features
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="$MANUL_DIR/config.json"
PID_FILE="$MANUL_DIR/daemon.pid"

# Configuration
DAEMON_LOG="$MANUL_DIR/daemon.log"
TASK_HEALTH_LOG="$MANUL_DIR/task-health.log"
WATCHDOG_LOG="$MANUL_DIR/watchdog.log"

start_daemon() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Manul daemon already running (pid $(cat "$PID_FILE"))"
        return 0
    fi
    
    echo "Starting manul daemon..."
    "$MANUL_DIR/manul-daemon.sh" start
    
    if [ -f "$PID_FILE" ]; then
        echo "Manul daemon started successfully (pid $(cat "$PID_FILE"))"
    else
        echo "ERROR: Failed to start manul daemon"
        return 1
    fi
}

stop_daemon() {
    if [ ! -f "$PID_FILE" ]; then
        echo "Manul daemon not running"
        return 0
    fi
    
    echo "Stopping manul daemon (pid $(cat "$PID_FILE"))..."
    "$MANUL_DIR/manul-daemon.sh" stop
    
    if [ ! -f "$PID_FILE" ]; then
        echo "Manul daemon stopped successfully"
    else
        echo "WARNING: Daemon may still be running"
    fi
}

status_all() {
    echo "=== Manul Automation Status ==="
    echo
    
    # Daemon status
    echo "1. Daemon Status:"
    "$MANUL_DIR/manul-daemon.sh" status
    echo
    
    # Task health service status
    local health_pid
    health_pid=$(pgrep -f "task-health-check.sh" | head -1)
    if [ -n "$health_pid" ]; then
        echo "2. Task Health Service:"
        echo "   RUNNING (pid: $health_pid)"
    else
        echo "2. Task Health Service:"
        echo "   STOPPED"
    fi
    echo
    
    # Recent logs
    if [ -f "$DAEMON_LOG" ] && [ -s "$DAEMON_LOG" ]; then
        echo "3. Recent Daemon Log (last 5 lines):"
        tail -5 "$DAEMON_LOG" | sed 's/^/   /'
        echo
    fi
    
    if [ -f "$TASK_HEALTH_LOG" ] && [ -s "$TASK_HEALTH_LOG" ]; then
        echo "4. Recent Task Health Log (last 5 lines):"
        tail -5 "$TASK_HEALTH_LOG" | sed 's/^/   /'
        echo
    fi
    
    # Stuck tasks
    echo "5. Stuck Tasks Analysis:"
    if [ -f "$MANUL_DIR/task-recovery.sh" ]; then
        "$MANUL_DIR/task-recovery.sh" --list-stuck | sed 's/^/   /' || true
    fi
    echo
}

install_components() {
    echo "=== Installing Enhanced Manul Automation ==="
    echo
    
    # 1. Ensure all scripts are executable
    echo "1. Setting permissions..."
    chmod +x "$MANUL_DIR/watchdog.sh" 2>/dev/null || true
    chmod +x "$MANUL_DIR/task-recovery.sh" 2>/dev/null || true
    chmod +x "$MANUL_DIR/task-health-check.sh" 2>/dev/null || true
    echo "   Scripts made executable"
    
    # 2. Install config if not exists
    if [ ! -f "$CONFIG" ]; then
        echo "2. Installing config..."
        cp "$MANUL_DIR/config.json.example" "$CONFIG" 2>/dev/null || {
            echo "WARNING: config.json.example not found"
            return 1
        }
        echo "   Config installed: $CONFIG"
    else
        echo "2. Config already exists: $CONFIG"
    fi
    
    # 3. Create log files
    echo "3. Setting up log files..."
    touch "$DAEMON_LOG" "$TASK_HEALTH_LOG" "$WATCHDOG_LOG" 2>/dev/null || {
        echo "WARNING: Could not create log files"
    }
    echo "   Log files initialized"
    
    # 4. Schedule cron jobs if not already present
    echo "4. Configuring cron jobs..."
    
    # Enhanced watchdog (every 5 minutes)
    if ! crontab -l 2>/dev/null | grep -q "watchdog.sh"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * $MANUL_DIR/watchdog.sh") | crontab -
        echo "   Added: enhanced watchdog (every 5 minutes)"
    else
        echo "   Enhanced watchdog already scheduled"
    fi
    
    # Task health check (every 2 minutes)
    if ! crontab -l 2>/dev/null | grep -q "task-health-check.sh"; then
        (crontab -l 2>/dev/null; echo "*/2 * * * * $MANUL_DIR/task-health-check.sh") | crontab -
        echo "   Added: task health check (every 2 minutes)"
    else
        echo "   Task health check already scheduled"
    fi
    
    # 5. Start services
    echo "5. Starting services..."
    start_daemon
    
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "   Manul daemon started"
        
        # Start task health monitor in background
        nohup "$MANUL_DIR/task-health-check.sh" >/dev/null 2>&1 &
        echo "   Task health monitor started"
        
        echo "\n=== Installation Complete ==="
        echo "Services are now running with enhanced automation features"
        echo "\nUseful commands:"
        echo "  $MANUL_DIR/manul-status.sh    - Show current status"
        echo "  $MANUL_DIR/task-recovery.sh --health-check - Run health check"
        echo "  $MANUL_DIR/task-recovery.sh --list-stuck - List stuck tasks"
        echo "  $MANUL_DIR/task-recovery.sh --reset <id> - Reset specific task"
        echo "\nLogs are written to:"
        echo "  $DAEMON_LOG"
        echo "  $TASK_HEALTH_LOG"
        echo "  $WATCHDOG_LOG"
        
        return 0
    else
        echo "   ERROR: Failed to start manul daemon"
        return 1
    fi
}

# --- MAIN ---
case "${1:-}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    status)
        status_all
        ;;
    restart)
        stop_daemon
        sleep 2
        start_daemon
        ;;
    install)
        install_components
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart|install}"
        echo
        echo "Commands:"
        echo "  start    Start all components"
        echo "  stop     Stop all components"
        echo "  status   Show status of all components"
        echo "  restart  Restart all components"
        echo "  install  Install and configure everything (recommended)"
        exit 1
        ;;
esac

exit 0