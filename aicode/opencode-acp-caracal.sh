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

# A long-lived OpenClaw Gateway may have an older environment than the current
# aicode launch. Refresh only Fiteo's pair from Manul's mode-600 runtime file,
# without re-sourcing unrelated operator settings or replacing Caracal's provider.
load_fiteo_mcp_environment() {
    local env_file="${MANUL_DIR:-$HOME/.manul}/.env"
    local values base_url pat
    [ -f "$env_file" ] || return 0
    values="$(bash -c 'set -e; . "$1" >/dev/null 2>&1; printf "%s|%s" "${FITEO_BASE_URL:-}" "${FITEO_PAT:-}"' _ "$env_file" 2>/dev/null)" || return 0
    IFS="|" read -r base_url pat <<< "$values"
    [ -n "$base_url" ] && [ -n "$pat" ] || return 0
    export FITEO_BASE_URL="$base_url" FITEO_PAT="$pat"
}
load_fiteo_mcp_environment

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
# Its aggregate exit code may be non-zero when an optional MCP (Fiteo) is down;
# only Caracal's explicit connected status gates the ACP session.
mcp_list_rc=0
mcp_output="$(timeout 45 "$opencode_bin" mcp list 2>&1)" || mcp_list_rc=$?
if ! printf '%s\n' "$mcp_output" | grep -Eiq 'caracal-rag[[:space:]].*connected|connected.*caracal-rag'; then
    log "OpenCode did not report caracal-rag as connected (mcp list exit $mcp_list_rc); refusing the ACP session"
    exit 78
fi

[ "${1:-}" = "acp" ] || {
    log "expected ACPX to invoke this wrapper with the 'acp' argument"
    exit 2
}
shift
log "Caracal MCP verified; starting OpenCode ACP"
exec "$opencode_bin" acp "$@"