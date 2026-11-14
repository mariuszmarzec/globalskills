#!/usr/bin/env bash
# Shared bounded readiness check for the required Caracal MCP in OpenCode.
# The HTTP endpoint may accept connections before OpenCode finishes MCP initialize.

opencode_mcp_url_is_valid() {
    python3 - "$1" <<'PY_MCP_URL'
import sys
from urllib.parse import urlsplit

value = sys.argv[1]
try:
    parsed = urlsplit(value)
    port = parsed.port
except ValueError:
    raise SystemExit(1)

if (
    parsed.scheme not in {"http", "https"}
    or not parsed.hostname
    or parsed.username is not None
    or parsed.password is not None
    or parsed.fragment
    or any(ord(char) <= 32 or ord(char) == 127 for char in value)
    or (port is not None and not 1 <= port <= 65535)
):
    raise SystemExit(1)
PY_MCP_URL
}

opencode_wait_for_mcp_connected() {
    local source_dir="$1"
    local opencode_cli="$2"
    local server_name="${3:-caracal-rag}"
    local wait_timeout="${OPENCODE_MCP_WAIT_TIMEOUT:-60}"
    local probe_timeout="${OPENCODE_MCP_PROBE_TIMEOUT:-10}"
    local retry_interval="${OPENCODE_MCP_RETRY_INTERVAL:-2}"
    local resolved_url="${CARACAL_MCP_URL:-}"
    local deadline remaining attempt_timeout sleep_for attempt=0 last_rc=0 last_output=""

    if [ "$server_name" = "caracal-rag" ]; then
        if ! opencode_mcp_url_is_valid "$resolved_url"; then
            echo "ERROR: CARACAL_MCP_URL is missing or is not an absolute HTTP(S) URL; refusing to start OpenCode." >&2
            return 1
        fi
        printf 'Verifying OpenCode MCP %s at %s.\n' "$server_name" "$resolved_url" >&2
    fi

    if ! [[ "$wait_timeout" =~ ^[0-9]{1,3}$ ]] ||
       (( wait_timeout < 1 || wait_timeout > 300 )); then
        wait_timeout=60
    fi
    if ! [[ "$probe_timeout" =~ ^[0-9]{1,2}$ ]] ||
       (( probe_timeout < 1 || probe_timeout > 60 )); then
        probe_timeout=10
    fi
    if ! [[ "$retry_interval" =~ ^[0-9]{1,2}$ ]] ||
       (( retry_interval < 1 || retry_interval > 10 )); then
        retry_interval=2
    fi

    OPENCODE_MCP_LAST_OUTPUT=""
    OPENCODE_MCP_LAST_STATUS=0
    deadline=$((SECONDS + wait_timeout))

    while (( SECONDS <= deadline )); do
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break

        attempt_timeout="$probe_timeout"
        if (( attempt_timeout > remaining )); then
            attempt_timeout="$remaining"
        fi

        last_rc=0
        last_output="$(python3 "$source_dir/run-with-timeout.py" "$attempt_timeout" "$opencode_cli" mcp list 2>&1)" || last_rc=$?
        OPENCODE_MCP_LAST_OUTPUT="$last_output"
        OPENCODE_MCP_LAST_STATUS="$last_rc"

        # Deterministic config errors will not resolve by retrying. Fail immediately
        # and show the exact non-secret endpoint passed to this OpenCode process.
        if printf '%s\n' "$last_output" | grep -Eiq 'invalid MCP URL|invalid URL for'; then
            if [ "$server_name" = "caracal-rag" ]; then
                printf 'ERROR: OpenCode rejected the Caracal MCP URL %s. Check the static mcp.servers entry and environment substitution.\n' "$resolved_url" >&2
            else
                printf 'ERROR: OpenCode rejected the URL for MCP server %s.\n' "$server_name" >&2
            fi
            printf '%s\n' "$last_output" >&2
            echo "No agent runtime will start." >&2
            return 1
        fi

        # Do not require a zero exit code: unrelated optional MCP servers may
        # be offline while the required Caracal server is already connected.
        if printf '%s\n' "$last_output" |
            grep -Eiq "(^|[[:space:]])$server_name[[:space:]]+connected([[:space:]]|$|\()"; then
            return 0
        fi

        if (( SECONDS >= deadline )); then
            break
        fi
        attempt=$((attempt + 1))
        printf 'Waiting for OpenCode MCP %s to report connected (retry %s; timeout %ss).\n' \
            "$server_name" "$attempt" "$wait_timeout" >&2

        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        sleep_for="$retry_interval"
        if (( sleep_for > remaining )); then
            sleep_for="$remaining"
        fi
        sleep "$sleep_for"
    done

    printf 'ERROR: OpenCode does not report %s as connected after %ss (last mcp list exit %s).\n' \
        "$server_name" "$wait_timeout" "$OPENCODE_MCP_LAST_STATUS" >&2
    if [ -n "$OPENCODE_MCP_LAST_OUTPUT" ]; then
        printf '%s\n' "$OPENCODE_MCP_LAST_OUTPUT" >&2
    else
        echo "The last 'opencode mcp list' attempt produced no output." >&2
    fi
    echo "No agent runtime will start." >&2
    return 1
}
