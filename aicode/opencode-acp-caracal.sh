#!/usr/bin/env bash
# opencode-acp-caracal.sh — OpenClaw ACPX command wrapper for OpenCode.
#
# ACPX starts this executable as the "opencode" harness. Resolve Caracal from
# the single Caracal provider (~/.caracal/env.sh) rather than trusting a possibly
# stale environment captured by a long-running OpenClaw Gateway process. Keep
# stdout reserved for the ACP JSON-RPC stream; all diagnostics go to stderr.
#
# This wrapper uses CARACAL_RESOLVE_LIVE=1 to force a fresh healthcheck for
# loopback URLs, ensuring an already-running Gateway cannot pin an old port.

set -euo pipefail
umask 077

export PATH="$HOME/.opencode/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

OPENCODE_ENV="$HOME/.config/opencode/opencode.env"
if [ -f "$OPENCODE_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$OPENCODE_ENV" >/dev/null
    set +a
fi

# Caracal provider: single source of CARACAL_MCP_URL and CARACAL_ACCESS_TOKEN.
# With CARACAL_RESOLVE_LIVE=1 it also probes the live loopback endpoint and
# fails closed if Caracal is not reachable.
CARACAL_HOME="${CARACAL_HOME:-$HOME/.caracal}"
# shellcheck source=~/.caracal/env.sh
CARACAL_RESOLVE_LIVE=1 . "$CARACAL_HOME/env.sh"

log() {
    printf 'opencode-acp-caracal: %s\n' "$*" >&2
}

if [ -n "${OPENCODE_CONFIG:-}" ]; then
    export OPENCODE_CONFIG
else
    OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
    export OPENCODE_CONFIG
fi
if [ ! -r "$OPENCODE_CONFIG" ]; then
    log "OpenCode config is missing/unreadable: $OPENCODE_CONFIG"
    exit 78
fi

if [ -n "${OPENCODE_BIN:-}" ] && [ -x "$OPENCODE_BIN" ]; then
    opencode_bin="$OPENCODE_BIN"
else
    opencode_bin="$(command -v opencode 2>/dev/null || true)"
fi
if [ -z "$opencode_bin" ] || [ ! -x "$opencode_bin" ]; then
    log "OpenCode CLI is not executable or not on PATH"
    exit 127
fi

# The CLI checks effective config, environment expansion, HTTP connection, and
# bearer authentication. Do not print its output; it may expose endpoint details.
if ! mcp_output="$(timeout 45 "$opencode_bin" mcp list 2>&1)" ||
   ! printf '%s\n' "$mcp_output" | grep -Eiq 'caracal-rag[[:space:]].*connected|connected.*caracal-rag'; then
    log "OpenCode did not report caracal-rag as connected; refusing the ACP session"
    exit 78
fi

[ "${1:-}" = "acp" ] || {
    log "expected ACPX to invoke this wrapper with the 'acp' argument"
    exit 2
}
shift
log "Caracal MCP verified; starting OpenCode ACP"
exec "$opencode_bin" acp "$@"