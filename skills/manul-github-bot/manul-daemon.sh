#!/usr/bin/bash
# manul-daemon.sh — background poll loop for the manul GitHub bot.
#
# Usage:
#   manul-daemon.sh start      — start the poll loop (setsid, survives gateway restarts)
#   manul-daemon.sh stop       — stop it
#   manul-daemon.sh status     — is it running?
#   manul-daemon.sh run-once   — single poll + dispatch (for testing)
#
# Loop: every $MANUL_INTERVAL (default from config pollInterval, else 60s) run
# poll.sh; when it reports fire:true, dispatch one headless agent turn via
# `openclaw agent --agent manul`. Dispatch is synchronous, so runs never
# overlap; the lock file is a backstop.
set -uo pipefail

# Ensure standard PATH is available when running via setsid/nohup
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="${MANUL_DIR}/config.json"
POLL="$MANUL_DIR/poll.sh"
PROMPT_FILE="$MANUL_DIR/orchestrator.prompt.md"
PID_FILE="$MANUL_DIR/daemon.pid"
LOG="$MANUL_DIR/daemon.log"
LOCK="$MANUL_DIR/lock"
CFG_INTERVAL="$(jq -r '.pollInterval // empty' "$CONFIG" 2>/dev/null)"
INTERVAL="${MANUL_INTERVAL:-${CFG_INTERVAL:-60}}"
AGENT_TIMEOUT="${MANUL_AGENT_TIMEOUT:-1800}"   # seconds for the agent turn
OPENCLAW_BIN="$(command -v openclaw)"

log() { echo "[$(date -Is)] $*" >>"$LOG"; }

start() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PID_FILE"))"
    return 0
  fi
  setsid nohup "$0" loop >>"$LOG" 2>&1 &
  echo $! >"$PID_FILE"
  echo "manul daemon started (pid $(cat "$PID_FILE"), interval ${INTERVAL}s)"
}

stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "not running"
    return 0
  fi
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null
  rm -f "$PID_FILE"
  echo "manul daemon stopped (pid $pid)"
}

status() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "running (pid $(cat "$PID_FILE"))"
  else
    echo "not running"
  fi
}

run_once() {
  out="$("$POLL")"
  echo "$out"
  if printf '%s' "$out" | grep -q '"fire":true'; then
    log "dispatch: $out"
    [ -f "$LOCK" ] || date +%s >"$LOCK"
    timeout -k 60 "$AGENT_TIMEOUT" "$OPENCLAW_BIN" agent --agent manul \
      --message-file "$PROMPT_FILE" >>"$LOG" 2>&1
    rc=$?
    echo "[$(date -Is)] agent turn finished rc=$rc" >>"$LOG"
    rm -f "$LOCK"
  fi
}

loop() {
  log "daemon loop started (interval ${INTERVAL}s)"
  while true; do
    run_once
    sleep "$INTERVAL"
  done
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  run-once) run_once ;;
  loop) loop ;;
  *) echo "usage: $0 start|stop|status|run-once" >&2; exit 2 ;;
esac
