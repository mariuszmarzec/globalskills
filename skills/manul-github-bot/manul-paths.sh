#!/usr/bin/env bash
# manul-paths.sh — Canonical path resolution for Manul runtime.
#
# This library must be sourced by every Manul component. It establishes the
# single source of truth for MANUL_DIR and derived paths.
#
# Default: $HOME/.manul (clean break from the legacy ~/.openclaw/manul layout).
# Override via the MANUL_DIR environment variable at invocation time.
#
# Derived paths (all relative to MANUL_DIR):
#   MANUL_CONFIG       config.json
#   MANUL_STATE_DIR    state/
#   MANUL_DB           state/manul.db
#   MANUL_LOG_DIR      logs/
#   MANUL_LOCKS_DIR    state/locks/
#   MANUL_TASKS_DIR    state/tasks/
#   MANUL_WORKSPACE    workspace/
#
# Intentionally does NOT define:
#   OPENCLAW_MANUL_DIR  — legacy alias, removed
#   Any OpenClaw/OpenCode-specific paths (those live in their adapters)

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
MANUL_CONFIG="${MANUL_CONFIG:-$MANUL_DIR/config.json}"
MANUL_STATE_DIR="${MANUL_STATE_DIR:-$MANUL_DIR/state}"
MANUL_DB="${MANUL_DB:-$MANUL_STATE_DIR/manul.db}"
MANUL_LOG_DIR="${MANUL_LOG_DIR:-$MANUL_DIR/logs}"
MANUL_LOCKS_DIR="${MANUL_LOCKS_DIR:-$MANUL_STATE_DIR/locks}"
MANUL_TASKS_DIR="${MANUL_TASKS_DIR:-$MANUL_STATE_DIR/tasks}"
MANUL_WORKSPACE="${MANUL_WORKSPACE:-$MANUL_DIR/workspace}"

# Runtime selection (default: openclaw). Environment overrides config.
# Config key: .automation.agentRuntime
_CONFIG_AGENT_RUNTIME=""
if [ -f "$MANUL_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    _CONFIG_AGENT_RUNTIME="$(jq -r '.automation.agentRuntime // ""' "$MANUL_CONFIG" 2>/dev/null || true)"
fi
AGENT_RUNTIME="${AGENT_RUNTIME:-${MANUL_AGENT_RUNTIME:-${_CONFIG_AGENT_RUNTIME:-openclaw}}}"

# Validate runtime selection early so downstream code can assert it.
case "$AGENT_RUNTIME" in
    openclaw|opencode) ;;
    "") AGENT_RUNTIME="openclaw" ;;
    *)
        echo "ERROR: Unknown agent runtime '$AGENT_RUNTIME'. Must be 'openclaw' or 'opencode'." >&2
        exit 1
        ;;
esac

# Ensure MANUL_STATE_DIR exists before we need it. Individual components may
# also create subdirs on demand; this is the canonical location guarantee.
mkdir -p "$MANUL_STATE_DIR" \
         "$MANUL_LOG_DIR" \
         "$MANUL_LOCKS_DIR" \
         "$MANUL_TASKS_DIR" \
         "$MANUL_WORKSPACE" \
         "$MANUL_DIR" \
  2>/dev/null || true
