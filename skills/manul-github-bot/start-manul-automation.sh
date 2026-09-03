#!/bin/bash
# start-manul-automation.sh — Manul automation startup/management wrapper
#
# Manages the canonical runtime components:
#   manul-daemon.sh  — background poll loop (polls GitHub, dispatches orchestrator)
#   watchdog.sh      — automatic recovery via cron (daemon liveness + heartbeat/lease)
#
# Does NOT start task-health-check.sh (legacy/deprecated).
# Does NOT create multiple recovery mechanisms.
#
# Usage:
#   start-manul-automation.sh start    — start daemon + install watchdog cron
#   start-manul-automation.sh stop     — stop daemon
#   start-manul-automation.sh status   — show daemon + watchdog status
#   start-manul-automation.sh restart  — stop then start

set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
DAEMON="$MANUL_DIR/manul-daemon.sh"
WATCHDOG="$MANUL_DIR/watchdog.sh"
WATCHDOG_CRON="*/5 * * * * $WATCHDOG"

log() { echo "[$(date -Is)] $*"; }

install_watchdog_cron() {
    # Install watchdog cron if not already present
    if crontab -l 2>/dev/null | grep -qF "$WATCHDOG"; then
        log "watchdog cron already installed"
    else
        (crontab -l 2>/dev/null; echo "$WATCHDOG_CRON") | crontab -
        log "watchdog cron installed (every 5 minutes)"
    fi
}

remove_watchdog_cron() {
    if crontab -l 2>/dev/null | grep -qF "$WATCHDOG"; then
        crontab -l 2>/dev/null | grep -vF "$WATCHDOG" | crontab -
        log "watchdog cron removed"
    fi
}

case "${1:-}" in
    start)
        log "Starting manul automation..."
        # Ensure scripts are executable
        chmod +x "$DAEMON" "$WATCHDOG" 2>/dev/null || true
        # Start daemon
        "$DAEMON" start
        # Install watchdog cron
        install_watchdog_cron
        log "Manul automation started"
        ;;
    stop)
        log "Stopping manul automation..."
        "$DAEMON" stop
        remove_watchdog_cron
        log "Manul automation stopped"
        ;;
    status)
        echo "=== Manul Automation Status ==="
        "$DAEMON" status
        echo ""
        echo "Watchdog cron:"
        if crontab -l 2>/dev/null | grep -qF "$WATCHDOG"; then
            echo "  installed (every 5 minutes)"
        else
            echo "  NOT installed"
        fi
        ;;
    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart}" >&2
        exit 1
        ;;
esac
