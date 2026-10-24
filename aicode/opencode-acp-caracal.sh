#!/usr/bin/env bash
# opencode-acp-caracal.sh — OpenClaw ACPX command wrapper for OpenCode.
#
# ACPX starts this executable as the "opencode" harness. Resolve Caracal from
# the current local config/secret store rather than trusting a possibly stale
# environment captured by a long-running OpenClaw Gateway process. Keep stdout
# reserved for the ACP JSON-RPC stream; all diagnostics go to stderr.

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

CARACAL_HOME="${CARACAL_HOME:-$HOME/.caracal}"
CARACAL_CLI="$CARACAL_HOME/bin/caracal-rag"
CARACAL_SECRETS="$CARACAL_HOME/config/secrets.yaml"
CARACAL_PYTHON="$CARACAL_HOME/venv/bin/python"

log() {
    printf 'opencode-acp-caracal: %s\n' "$*" >&2
}

load_caracal_token() {
    [ -x "$CARACAL_PYTHON" ] && [ -f "$CARACAL_SECRETS" ] || return 1
    "$CARACAL_PYTHON" - "$CARACAL_SECRETS" <<'PY'
import sys
from pathlib import Path
from caracal_rag.config import load_secrets

token = load_secrets(Path(sys.argv[1])).get("access_token", "")
if not token:
    raise SystemExit("Caracal access token is missing")
print(token, end="")
PY
}

# If the URL is loopback (the normal aicode deployment), resolve it afresh from
# the Caracal healthcheck so an already-running Gateway cannot pin an old port.
# Non-loopback URLs are considered explicitly configured external endpoints.
current_url="${CARACAL_MCP_URL:-}"
case "$current_url" in
    ""|http://127.0.0.1:0/*|http://127.0.0.1:*|http://localhost:*|http://[::1]:*)
        if [ ! -x "$CARACAL_CLI" ]; then
            log "Caracal CLI is unavailable: $CARACAL_CLI"
            exit 78
        fi
        if ! check_output="$("$CARACAL_CLI" check 2>/dev/null)"; then
            log "Caracal healthcheck failed; refusing to start the ACP harness"
            exit 78
        fi
        mcp_host="$(printf '%s\n' "$check_output" | sed -n 's/.*mcp_host=\([^ ]*\).*/\1/p' | tail -n 1)"
        mcp_port="$(printf '%s\n' "$check_output" | sed -n 's/.*mcp_port=\([^ ]*\).*/\1/p' | tail -n 1)"
        mcp_path="$(printf '%s\n' "$check_output" | sed -n 's/.*mcp_path=\([^ ]*\).*/\1/p' | tail -n 1)"
        if [ "$mcp_host" != "127.0.0.1" ] ||
           ! [[ "$mcp_port" =~ ^[0-9]{1,5}$ ]] ||
           (( mcp_port < 1 || mcp_port > 65535 )) ||
           ! [[ "$mcp_path" =~ ^/[A-Za-z0-9/_-]+$ ]]; then
            log "Caracal config must use loopback HTTP with a valid port and MCP path"
            exit 78
        fi
        CARACAL_MCP_URL="http://127.0.0.1:$mcp_port$mcp_path"
        if ! CARACAL_ACCESS_TOKEN="$(load_caracal_token 2>/dev/null)"; then
            log "could not load the current Caracal access token"
            exit 78
        fi
        ;;
    *)
        case "$current_url" in
            http://*|https://*) ;;
            *) log "CARACAL_MCP_URL must be an absolute HTTP(S) URL"; exit 78 ;;
        esac
        if [ -z "${CARACAL_ACCESS_TOKEN:-}" ]; then
            if ! CARACAL_ACCESS_TOKEN="$(load_caracal_token 2>/dev/null)"; then
                log "Caracal access token is missing"
                exit 78
            fi
        fi
        CARACAL_MCP_URL="$current_url"
        ;;
esac
if [ -z "${CARACAL_ACCESS_TOKEN:-}" ]; then
    log "Caracal access token is empty"
    exit 78
fi
export CARACAL_HOME CARACAL_MCP_URL CARACAL_ACCESS_TOKEN

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
if ! mcp_output="$("$opencode_bin" mcp list 2>&1)" ||
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
