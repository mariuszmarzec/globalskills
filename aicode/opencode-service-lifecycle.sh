#!/usr/bin/env bash
# Refresh the shared OpenCode service at aicode startup when its Caracal MCP
# connection is stale. Never restart the service while it has active work or
# connected clients. Manul task execution must not call this helper.

aicode_opencode_service_registration_file() {
    printf '%s' "${AICODE_OPENCODE_SERVICE_INFO_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json}"
}

aicode_opencode_registered_service_pid() {
    local registration pid state command_line
    registration="$(aicode_opencode_service_registration_file)"
    [ -r "$registration" ] || return 1

    pid="$(jq -er '.pid | select(type == "number" and . > 1) | floor' "$registration" 2>/dev/null)" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    state="$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]')" || return 1
    case "$state" in
        ""|Z*|z*) return 1 ;;
    esac
    command_line="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1
    case "$command_line" in
        *opencode*serve*--service*) printf '%s' "$pid" ;;
        *) return 1 ;;
    esac
}

# Resolve the executable that is actually running the registered shared service.
# On Linux/WSL /proc/<pid>/exe is authoritative and resolves symlinks. On macOS,
# use the service's argv[0], with lsof as a fallback. Never guess via PATH here:
# PATH may point at an unrelated wrapper with the same command name.
aicode_opencode_registered_service_executable() {
    local pid="${1:-}" proc_root proc_exe executable command_line

    if [ -z "$pid" ]; then
        pid="$(aicode_opencode_registered_service_pid)" || return 1
    fi
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    proc_root="${AICODE_OPENCODE_PROC_ROOT:-/proc}"
    proc_exe="$proc_root/$pid/exe"
    if [ -L "$proc_exe" ]; then
        executable="$(readlink "$proc_exe" 2>/dev/null || true)"
    fi

    if [ -z "$executable" ] || [ ! -x "$executable" ]; then
        command_line="$(ps -p "$pid" -o args= 2>/dev/null)" || command_line=""
        if [ -n "$command_line" ]; then
            executable="$(printf '%s' "$command_line" | python3 -c '
import shlex
import sys
try:
    arguments = shlex.split(sys.stdin.read())
except ValueError:
    raise SystemExit(1)
if not arguments:
    raise SystemExit(1)
print(arguments[0])
' 2>/dev/null || true)"
        fi
    fi

    # Some platforms expose only a process name in argv[0]. lsof can resolve
    # the executable image without consulting the current shell's PATH.
    if [ -z "$executable" ] || [[ "$executable" != /* ]] || [ ! -x "$executable" ]; then
        if command -v lsof >/dev/null 2>&1; then
            executable="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null |
                awk 'substr($0, 1, 2) == "n/" { print substr($0, 2); exit }')"
        fi
    fi

    if [[ "$executable" != /* ]] || [ ! -x "$executable" ]; then
        echo "ERROR: cannot resolve the executable for shared OpenCode PID $pid without guessing from PATH." >&2
        return 1
    fi
    printf '%s' "$executable"
}

# OPENCODE_BIN is an explicit operator override. Otherwise, reuse the exact
# executable that owns the registered service; consult PATH only for first start.
aicode_opencode_resolve_cli() {
    local service_pid executable

    if [ -n "${OPENCODE_BIN:-}" ]; then
        if [ ! -x "$OPENCODE_BIN" ]; then
            echo "ERROR: OPENCODE_BIN is set but is not executable: $OPENCODE_BIN" >&2
            return 2
        fi
        printf '%s' "$OPENCODE_BIN"
        return 0
    fi

    service_pid="$(aicode_opencode_registered_service_pid 2>/dev/null || true)"
    if [ -n "$service_pid" ]; then
        executable="$(aicode_opencode_registered_service_executable "$service_pid")" || return 2
        printf '%s' "$executable"
        return 0
    fi

    command -v opencode 2>/dev/null
}

aicode_opencode_api_get() {
    local source_dir="$1"
    local opencode_cli="$2"
    local path="$3"
    local timeout_seconds="${4:-8}"
    python3 "$source_dir/run-with-timeout.py" "$timeout_seconds" "$opencode_cli" api get "$path"
}

aicode_opencode_has_established_clients() {
    local registration port count
    registration="$(aicode_opencode_service_registration_file)"
    port="$(python3 - "$registration" <<'PY_OPENCODE_PORT'
import json
import sys
from urllib.parse import urlsplit
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        info = json.load(stream)
    port = urlsplit(info.get("url", "")).port
except (OSError, ValueError, TypeError):
    raise SystemExit(2)
if not isinstance(port, int) or not 1 <= port <= 65535:
    raise SystemExit(2)
print(port)
PY_OPENCODE_PORT
)" || return 2

    # A connected TUI/browser keeps a long-lived HTTP event stream open. The
    # service restart command drops its PTYs, so any established client socket
    # is treated as a reason not to restart.
    if command -v ss >/dev/null 2>&1; then
        count="$(ss -Htn state established "( sport = :$port )" 2>/dev/null | awk 'END { print NR + 0 }')" || return 2
    elif command -v lsof >/dev/null 2>&1; then
        count="$(lsof -nP -iTCP:"$port" -sTCP:ESTABLISHED 2>/dev/null | awk 'NR > 1 { count++ } END { print count + 0 }')" || return 2
    else
        return 2
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || return 2
    [ "$count" -gt 0 ]
}

aicode_opencode_no_running_ptys() {
    local source_dir="$1"
    local opencode_cli="$2"
    local projects_json project_id worktrees_json directory encoded_directory
    local pty_json running_count
    local -a project_ids=() directories=()
    local -A seen_directories=()

    # PTYs are scoped by OpenCode location, not just by the current shell
    # directory. Inspect every saved project (including archived ones), its
    # registered worktrees, and the directory from which aicode was launched.
    projects_json="$(aicode_opencode_api_get "$source_dir" "$opencode_cli" "/api/project?archived=true" 8 2>/dev/null)" || {
        echo "ERROR: cannot enumerate OpenCode projects; refusing to restart the shared service." >&2
        return 2
    }
    if ! jq -e 'if type == "array" then true else (.data | type == "array") end' >/dev/null 2>&1 <<<"$projects_json"; then
        echo "ERROR: OpenCode returned an invalid project inventory; refusing to restart the shared service." >&2
        return 2
    fi
    mapfile -t project_ids < <(jq -r '(if type == "array" then . else .data end)[] | .id // empty' <<<"$projects_json")
    mapfile -t directories < <(jq -r '(if type == "array" then . else .data end)[] | .canonical // empty, (.sandboxes[]? // empty)' <<<"$projects_json")

    for project_id in "${project_ids[@]}"; do
        [ -n "$project_id" ] || continue
        worktrees_json="$(aicode_opencode_api_get "$source_dir" "$opencode_cli" "/api/worktree?projectID=$project_id" 8 2>/dev/null)" || {
            echo "ERROR: cannot enumerate worktrees for OpenCode project $project_id; refusing to restart the shared service." >&2
            return 2
        }
        if ! jq -e 'if type == "array" then true else (.data | type == "array") end' >/dev/null 2>&1 <<<"$worktrees_json"; then
            echo "ERROR: OpenCode returned an invalid worktree inventory for project $project_id; refusing to restart the shared service." >&2
            return 2
        fi
        while IFS= read -r directory; do
            [ -n "$directory" ] && directories+=("$directory")
        done < <(jq -r '(if type == "array" then . else .data end)[] | .directory // empty' <<<"$worktrees_json")
    done
    directories+=("$PWD")

    for directory in "${directories[@]}"; do
        [ -n "$directory" ] || continue
        if [ -n "${seen_directories[$directory]:-}" ]; then
            continue
        fi
        seen_directories["$directory"]=1
        encoded_directory="$(printf '%s' "$directory" | jq -sRr @uri)" || return 2
        pty_json="$(aicode_opencode_api_get "$source_dir" "$opencode_cli" "/api/pty?location%5Bdirectory%5D=$encoded_directory" 8 2>/dev/null)" || {
            echo "ERROR: cannot inspect OpenCode terminals in $directory; refusing to restart the shared service." >&2
            return 2
        }
        if ! jq -e 'if type == "array" then true else (.data | type == "array") end' >/dev/null 2>&1 <<<"$pty_json"; then
            echo "ERROR: OpenCode returned an invalid terminal inventory for $directory; refusing to restart the shared service." >&2
            return 2
        fi
        running_count="$(jq '[ (if type == "array" then . else .data end)[] | select(.status == "running") ] | length' <<<"$pty_json")" || return 2
        if [ "$running_count" -gt 0 ]; then
            echo "ERROR: OpenCode has $running_count running terminal(s) in $directory; refusing to restart the shared service." >&2
            echo "Close those terminals, then rerun aicode to refresh Caracal's environment." >&2
            return 1
        fi
    done
    return 0
}

aicode_opencode_caracal_service_ready() {
    local source_dir="$1"
    local opencode_cli="$2"
    local registration existing_pid active_json
    local active_count pty_check_rc probe_wait restart_timeout

    if [ ! -r "$source_dir/opencode-mcp-readiness.sh" ] || [ ! -r "$source_dir/run-with-timeout.py" ]; then
        echo "ERROR: OpenCode readiness helpers are missing; cannot verify Caracal safely." >&2
        return 1
    fi
    # shellcheck source=aicode/opencode-mcp-readiness.sh
    . "$source_dir/opencode-mcp-readiness.sh"

    registration="$(aicode_opencode_service_registration_file)"
    existing_pid="$(aicode_opencode_registered_service_pid 2>/dev/null || true)"

    if [ -z "$existing_pid" ]; then
        # No pre-existing shared service: the first CLI request will create it
        # from this aicode process, which already loaded ~/.caracal/env.sh.
        OPENCODE_MCP_WAIT_TIMEOUT="${AICODE_OPENCODE_NEW_SERVICE_WAIT_SECONDS:-60}" \
            opencode_wait_for_mcp_connected "$source_dir" "$opencode_cli" "caracal-rag"
        return $?
    fi

    probe_wait="${AICODE_OPENCODE_EXISTING_SERVICE_WAIT_SECONDS:-8}"
    if ! [[ "$probe_wait" =~ ^[0-9]{1,2}$ ]] || [ "$probe_wait" -lt 1 ] || [ "$probe_wait" -gt 30 ]; then
        probe_wait=8
    fi
    # First give the existing service a brief opportunity to complete a
    # delayed MCP initialize. Do not restart merely because Caracal is still
    # warming up.
    if OPENCODE_MCP_WAIT_TIMEOUT="$probe_wait" OPENCODE_MCP_PROBE_TIMEOUT=3 OPENCODE_MCP_RETRY_INTERVAL=1 \
        opencode_wait_for_mcp_connected "$source_dir" "$opencode_cli" "caracal-rag" 2>/dev/null; then
        return 0
    fi
    if printf '%s' "${OPENCODE_MCP_LAST_OUTPUT:-}" | grep -Eiq 'invalid MCP URL|invalid URL for'; then
        echo "ERROR: OpenCode rejected the configured Caracal MCP URL; not restarting the shared service." >&2
        return 1
    fi

    # Agent activity is global to the service. Check it before inspecting
    # location-scoped PTYs; never restart underneath a running agent session.
    active_json="$(aicode_opencode_api_get "$source_dir" "$opencode_cli" "/api/session/active" 8 2>/dev/null)" || {
        echo "ERROR: cannot inspect active OpenCode sessions; refusing to restart the shared service." >&2
        return 1
    }
    if ! jq -e '.data | type == "object"' >/dev/null 2>&1 <<<"$active_json"; then
        echo "ERROR: OpenCode returned an invalid active-session response; refusing to restart the shared service." >&2
        return 1
    fi
    active_count="$(jq -r '.data | length' <<<"$active_json")" || return 1
    if [ "$active_count" -gt 0 ]; then
        echo "ERROR: OpenCode has $active_count active agent session(s); refusing to restart the shared service." >&2
        echo "Finish those sessions, then rerun aicode to refresh Caracal's environment." >&2
        return 1
    fi

    # A restart is only allowed after proving the shared server is idle.
    # Enumerate every saved project and registered worktree because PTYs are
    # location-scoped and service restart tears down all server-owned PTYs.
    if aicode_opencode_no_running_ptys "$source_dir" "$opencode_cli"; then
        :
    else
        pty_check_rc=$?
        if [ "$pty_check_rc" -eq 1 ]; then
            return 1
        fi
        echo "ERROR: cannot prove the shared OpenCode service has no running terminals; refusing restart." >&2
        return 1
    fi

    if aicode_opencode_has_established_clients; then
        echo "ERROR: OpenCode has connected clients; refusing to restart the shared service." >&2
        echo "Close OpenCode TUI/browser clients, then rerun aicode to refresh Caracal's environment." >&2
        return 1
    else
        local socket_check_rc=$?
        if [ "$socket_check_rc" -ne 1 ]; then
            echo "ERROR: cannot determine whether OpenCode clients are connected; refusing to restart the shared service." >&2
            return 1
        fi
    fi

    echo "Caracal is disconnected in the idle shared OpenCode service; refreshing it once from aicode's current environment." >&2
    restart_timeout="${AICODE_OPENCODE_SERVICE_RESTART_TIMEOUT_SECONDS:-30}"
    if ! [[ "$restart_timeout" =~ ^[0-9]{1,2}$ ]] || [ "$restart_timeout" -lt 5 ] || [ "$restart_timeout" -gt 60 ]; then
        restart_timeout=30
    fi
    if ! python3 "$source_dir/run-with-timeout.py" "$restart_timeout" "$opencode_cli" service restart >/dev/null; then
        echo "ERROR: OpenCode shared service restart failed; see the OpenCode service diagnostics." >&2
        return 1
    fi

    OPENCODE_MCP_WAIT_TIMEOUT="${AICODE_OPENCODE_NEW_SERVICE_WAIT_SECONDS:-60}" \
        opencode_wait_for_mcp_connected "$source_dir" "$opencode_cli" "caracal-rag"
}
