#!/usr/bin/env bash
# opencode-adapter.sh — OpenCode runtime adapter for AgentExecutor.
#
# Independent backend: it does not import, invoke, or configure OpenClaw.
# Uses the documented non-interactive CLI:
#   opencode run [message...] --format json --dir <workspace>
# and resumes a saved session with:
#   opencode run --session <session-id> ...
#
# JSON mode exposes sessionID on events. We persist that ID only when the
# runtime reports a step-limit continuation condition. Text events are
# normalized back to plain task output so Manul control markers remain
# line-oriented and compatible with the existing daemon contract.

set -u

MANUL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$MANUL_SCRIPT_DIR/manul-paths.sh"
source "$MANUL_SCRIPT_DIR/process-runner.sh"

OPT_TASK_ID=""
OPT_PROMPT=""
OPT_WORKSPACE=""
OPT_AGENT=""
OPT_ATTEMPT=1
OPT_TIMEOUT=0
OPT_SESSION_ID=""
OPT_STDOUT_FILE=""
OPT_STDERR_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id)     OPT_TASK_ID="$2";     shift 2 ;;
        --prompt)      OPT_PROMPT="$2";      shift 2 ;;
        --workspace)   OPT_WORKSPACE="$2";   shift 2 ;;
        --agent)       OPT_AGENT="$2";       shift 2 ;;
        --attempt)     OPT_ATTEMPT="$2";     shift 2 ;;
        --timeout)     OPT_TIMEOUT="$2";     shift 2 ;;
        --session-id)  OPT_SESSION_ID="$2";  shift 2 ;;
        --stdout-file) OPT_STDOUT_FILE="$2"; shift 2 ;;
        --stderr-file) OPT_STDERR_FILE="$2"; shift 2 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$OPT_TASK_ID" ] || [ -z "$OPT_PROMPT" ] || [ -z "$OPT_WORKSPACE" ]; then
    printf '{"status":"FAILED","task_id":"","exit_code":1,"summary":"Missing required args (task-id/prompt/workspace)","session_id":"","duration_s":0}\n'
    exit 1
fi
if [ ! -f "$OPT_PROMPT" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":1,"summary":"Prompt file not found","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 1
fi
if [ ! -d "$OPT_WORKSPACE" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Workspace directory not found","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 66
fi

# Known install locations for the OpenCode CLI, in priority order. The binary
# is commonly installed at $HOME/.opencode/bin (added by the OpenCode installer
# to the interactive shell PATH only), but the daemon worker inherits a
# non-interactive PATH that omits it — exactly the failure mode that already
# bit the OpenClaw adapter. Explicit OPENCODE_BIN always wins; otherwise PATH;
# otherwise these well-known locations are probed before giving up.
OPENCODE_KNOWN_DIRS=(
    "$HOME/.opencode/bin"
    "$HOME/.local/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
)

_resolve_opencode_bin() {
    if [ -n "${OPENCODE_BIN:-}" ] && [ -x "$OPENCODE_BIN" ]; then
        printf '%s' "$OPENCODE_BIN"
        return 0
    fi
    local found
    found="$(command -v opencode 2>/dev/null || true)"
    if [ -n "$found" ] && [ -x "$found" ]; then
        printf '%s' "$found"
        return 0
    fi
    local dir bin
    for dir in "${OPENCODE_KNOWN_DIRS[@]}"; do
        bin="$dir/opencode"
        if [ -x "$bin" ]; then
            printf '%s' "$bin"
            return 0
        fi
    done
    return 1
}
OPENCODE_BIN="$(_resolve_opencode_bin)"
if [ -z "$OPENCODE_BIN" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":127,"summary":"OpenCode binary not found (opencode not on PATH or known dirs)","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 127
fi
export OPENCODE_BIN
# Surface the resolution path in diagnostics so a future failure is not a
# silent empty-stderr death like the one this fix addresses.
if [ -n "${OPENCODE_BIN_OVERRIDE:-}" ]; then
    _OC_SOURCE="OPENCODE_BIN override"
elif command -v opencode >/dev/null 2>&1; then
    _OC_SOURCE="PATH"
else
    _OC_SOURCE="known-dir fallback"
fi
export _OC_SOURCE

AGENT_TIMEOUT="${OPT_TIMEOUT:-0}"
if ! [[ "$AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_TIMEOUT" -lt 1 ]; then
    AGENT_TIMEOUT="${MANUL_OPENCODE_AGENT_TIMEOUT:-43200}"
fi
if ! [[ "$AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_TIMEOUT" -lt 1 ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":2,"summary":"Invalid OpenCode timeout","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 2
fi

PROMPT_CONTENT="$(cat "$OPT_PROMPT")"
if [ -n "$OPT_SESSION_ID" ]; then
    # A continuation already has the complete task history in the OpenCode
    # session. Replaying the large original prompt can make the model reopen
    # the plan instead of finishing the pending work.
    RUN_PROMPT="Continue exactly where you left off. Do not re-plan or restate the task. Make the next concrete changes in the current workspace, run the relevant checks, and finish the task. When the task is genuinely complete, emit exactly one final line: TASK_DONE"
else
    RUN_PROMPT="$PROMPT_CONTENT"
fi
SESSION_ARGS=()
if [ -n "$OPT_SESSION_ID" ]; then
    SESSION_ARGS=(--session "$OPT_SESSION_ID")
fi
AGENT_ARGS=()
if [ -n "$OPT_AGENT" ]; then
    AGENT_ARGS=(--agent "$OPT_AGENT")
fi

RAW_STDOUT_FILE="${MANUL_TASK_LOG_DIR:-$(dirname "$OPT_STDOUT_FILE")}/task-${OPT_TASK_ID}.attempt-${OPT_ATTEMPT}.opencode.jsonl"
# Keep RAW_STDOUT_FILE as the canonical per-attempt runtime diagnostic artifact.
mkdir -p "$(dirname "$OPT_STDOUT_FILE")" "$(dirname "$OPT_STDERR_FILE")" 2>/dev/null || true

log() {
    echo "[$(date -Is)] opencode-adapter: $*" >>"$OPT_STDERR_FILE"
}
log "starting task=$OPT_TASK_ID attempt=$OPT_ATTEMPT role=${OPT_AGENT:-<automatic>} session=${OPT_SESSION_ID:-<new>} timeout=${AGENT_TIMEOUT}s opencode=$OPENCODE_BIN source=${_OC_SOURCE:-unknown} workspace=$OPT_WORKSPACE"

# ProcessRunner is the only process boundary. The raw JSONL is retained as a
# per-attempt diagnostic artifact; OPT_STDOUT_FILE is rewritten below into plain
# agent text/control markers.
ProcessRunner_TmpStdout="$RAW_STDOUT_FILE"
ProcessRunner_TmpStderr="$OPT_STDERR_FILE"

# Replace any inherited Python path with this task's checkout roots. This
# prevents a stale workspace injected by the daemon's environment from taking
# precedence over the source being tested. Keep PYTHONHOME unset as well.
# Capture ProcessRunner output so its protocol line cannot leak into the
# adapter stdout. AgentExecutor/AgentExecutionController expect stdout to
# contain exactly one final ExecutionResult JSON document.
local_runner_result="$(ProcessRunner.run \
    --timeout "$AGENT_TIMEOUT" \
    --cwd "$OPT_WORKSPACE" \
    -- env -u PYTHONHOME "PYTHONPATH=$OPT_WORKSPACE/src:$OPT_WORKSPACE" "$OPENCODE_BIN" run \
        "${SESSION_ARGS[@]}" \
        "${AGENT_ARGS[@]}" \
        --format json \
        --dir "$OPT_WORKSPACE" \
        "$RUN_PROMPT")"
pr_rc=$?
: "$local_runner_result"

session_id=""
if [ -f "$RAW_STDOUT_FILE" ]; then
    session_id="$(jq -Rr 'try fromjson catch empty | .sessionID // empty' "$RAW_STDOUT_FILE" 2>/dev/null | awk 'length { print; exit }')"
fi
if [ -z "$session_id" ]; then
    session_id="$OPT_SESSION_ID"
fi

: >"$OPT_STDOUT_FILE"
if [ -f "$RAW_STDOUT_FILE" ]; then
    jq -Rr 'try fromjson catch empty | select(.type == "text") | (.part.text // .text // empty)' \
        "$RAW_STDOUT_FILE" 2>/dev/null >>"$OPT_STDOUT_FILE" || true
fi

# OpenCode has had versions/environment combinations where text events are
# missing from normalized output. Recover markers only from actual text events:
# arbitrary raw JSONL may contain tokens in tool calls or documentation.
if [ -s "$RAW_STDOUT_FILE" ]; then
    normalized_text_events="$(jq -Rr '
        try fromjson catch empty
        | select(.type == "text")
        | (.part.text // .text // empty)
    ' "$RAW_STDOUT_FILE" 2>/dev/null || true)"

    for marker in TASK_DONE TASK_FAILED TASK_NEEDS_USER_BEGIN TASK_NEEDS_USER_END; do
        if ! grep -qE "^${marker}($|[[:space:]:])" "$OPT_STDOUT_FILE" 2>/dev/null; then
            marker_line="$(printf '%s\n' "$normalized_text_events" |
                grep -E "^${marker}($|[[:space:]:])" | head -n 1 || true)"
            if [ -n "$marker_line" ]; then
                printf '%s\n' "$marker_line" >>"$OPT_STDOUT_FILE"
            fi
        fi
    done
fi

duration="0"
if [ -s "$RAW_STDOUT_FILE" ]; then
    duration="$(awk 'BEGIN { start=0; end=0 } /"timestamp":/ {
        if (match($0, /"timestamp":[0-9]+/)) {
            v=substr($0, RSTART+12, RLENGTH-12)
            if (start == 0) start=v
            end=v
        }
    } END {
        if (start > 0 && end >= start) printf "%.3f", (end-start)/1000
    }' "$RAW_STDOUT_FILE" 2>/dev/null || true)"
fi
: "${duration:=0}"

_status="FAILED"
_exit_code="$pr_rc"
_summary=""

# Extract the most useful structured runtime diagnostics before interpreting the
# result. Keep the full JSONL file on disk; only a compact summary is surfaced
# in GitHub lifecycle comments.
error_message=""
error_type=""
error_source=""
last_event_type=""
if [ -s "$RAW_STDOUT_FILE" ]; then
    error_message="$(jq -Rr 'try fromjson catch empty | select(.type == "error") | (.error.message // .message // empty)' "$RAW_STDOUT_FILE" 2>/dev/null | awk 'length { print; exit }')"
    error_type="$(jq -Rr 'try fromjson catch empty | select(.type == "error") | (.error.name // .error.type // empty)' "$RAW_STDOUT_FILE" 2>/dev/null | awk 'length { print; exit }')"
    last_event_type="$(jq -Rr 'try fromjson catch empty | .type // empty' "$RAW_STDOUT_FILE" 2>/dev/null | awk 'length { value=$0 } END { print value }')"
    if [ -n "$error_message" ]; then
        error_source="runtime_jsonl"
    fi
fi

# A tool call that the runtime itself rejected is not a recoverable continuation:
# the agent hit a hard permission boundary mid-run and exited without a completion
# marker. Surface it as an explicit recoverable failure so the daemon retries with
# a different approach instead of silently treating it as "session can continue".
permission_blocked=0
permission_operation=""
permission_detail=""
permission_tool=""
# Extract a compact description of the denied operation, not the raw event.
# OpenCode event shapes differ across versions; avoid publishing arguments,
# prompt contents, or arbitrary event JSON to GitHub.
if [ -s "$RAW_STDOUT_FILE" ]; then
    permission_event="$(jq -c '
      select(.type == "tool_use")
      | select(.part.state.status == "error")
      | select((.part.state.error // "") | tostring | test("permission|rejected|auto-reject"; "i"))
    ' "$RAW_STDOUT_FILE" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$permission_event" ]; then
        permission_blocked=1
        permission_tool="$(printf '%s' "$permission_event" | jq -r '.part.tool // .part.name // .part.state.tool // .tool // empty' 2>/dev/null)"
        permission_tool="$(printf '%s' "$permission_tool" | tr '\n\r' '  ' | cut -c1-80)"
        permission_detail="$(printf '%s' "$permission_event" | jq -r '.part.state.error // .part.error // .error // empty' 2>/dev/null)"
        permission_detail="$(printf '%s' "$permission_detail" | tr '\n\r' '  ' | sed -E 's/(Bearer|token|api[_ -]?key|password|secret)[=: ]+[^ ]+/\1=[REDACTED]/Ig' | cut -c1-300)"
        permission_operation="$(printf '%s' "$permission_detail" | sed -nE 's/.*permission requested: ([^;]+).*/\1/ip' | head -n1)"
    fi
fi
# Use stderr to enrich a generic structured permission rejection when the
# JSONL event omits the concrete target. Do not let incidental stderr text
# override a specific, structured non-permission error (for example, ProviderError).
stderr_permission_line=""
stderr_permission_operation=""
if [ -s "$OPT_STDERR_FILE" ]; then
    stderr_permission_line="$(grep -Ei 'permission requested: [^;]+; auto-rejecting' "$OPT_STDERR_FILE" 2>/dev/null | tail -n 1 | tr '\n\r' '  ' | cut -c1-400 || true)"
    if [ -n "$stderr_permission_line" ]; then
        stderr_permission_operation="$(printf '%s' "$stderr_permission_line" | sed -nE 's/.*permission requested: ([^;]+); auto-rejecting.*/\1/ip' | head -n 1)"
        if [ "$permission_blocked" -eq 0 ] && [ -z "$error_message" ]; then
            permission_blocked=1
        fi
        if [ "$permission_blocked" -eq 1 ]; then
            [ -n "$permission_operation" ] || permission_operation="$stderr_permission_operation"
            if [ -z "$permission_tool" ] && [ -n "$stderr_permission_operation" ]; then
                permission_tool="$(printf '%s' "$stderr_permission_operation" | awk '{print $1}')"
            fi
        fi
    fi
fi
if [ "$permission_blocked" -eq 1 ]; then
    # A bash permission target can contain the full shell command. Never
    # publish those tool arguments; retain only a recognizable Manul workspace
    # root where present so an out-of-scope workspace access is still actionable.
    if [ "$permission_tool" = "bash" ] || printf '%s' "$permission_operation" | grep -Eq '^bash([[:space:]]|\\()'; then
        denied_workspace_path="$(printf '%s' "$permission_operation" | grep -oE '/[^[:space:];()&]*/\\.manul/workspace/ws-[^/[:space:]();&]+' | head -n 1 || true)"
        if [ -n "$denied_workspace_path" ]; then
            permission_operation="bash (external workspace: $denied_workspace_path; command redacted)"
        else
            permission_operation="bash (command details redacted)"
        fi
        [ -n "$permission_tool" ] || permission_tool="bash"
    fi
    error_type="RUNTIME_PERMISSION_BLOCKED"
    error_source="runtime_jsonl"
    if [ -n "$permission_operation" ]; then
        error_message="Denied access: $permission_operation"
    elif [ -n "$permission_detail" ]; then
        error_message="$permission_detail"
    else
        error_message="OpenCode tool call rejected by runtime permission policy; operation details were not present in captured diagnostics"
    fi
    if [ -n "$permission_tool" ]; then
        error_message="$error_message (tool: $permission_tool)"
    fi
fi
if [ -z "$error_message" ] && [ -s "$OPT_STDERR_FILE" ]; then
    error_message="$(grep -Eio '.*(permission requested|auto-rejecting|error|failed|denied|refused|timeout).*' "$OPT_STDERR_FILE" 2>/dev/null | tail -n 1 | sed 's/[[:space:]]\+$//' || true)"
    if [ -n "$error_message" ]; then
        error_source="stderr"
        if printf "%s" "$error_message" | grep -Eqi 'permission requested|auto-rejecting|permission denied|denied'; then
            error_type="PermissionError"
        fi
    fi
fi

if [ "$pr_rc" -eq 124 ]; then
    _status="TIMEOUT"
    _summary="OpenCode execution timed out after ${AGENT_TIMEOUT}s"
elif grep -qE '^TASK_NEEDS_USER_BEGIN([[:space:]]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; then
    _status="BLOCKED"
    _exit_code=0
    _summary="OpenCode agent needs user input"
elif grep -qE '^TASK_FAILED([[:space:]:]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; then
    _status="FAILED"
    _summary="OpenCode agent reported TASK_FAILED"
elif grep -qE '^TASK_DONE([[:space:]]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; then
    if [ "$pr_rc" -eq 0 ]; then
        _status="COMPLETED"
        _exit_code=0
        _summary="$(grep -oP '(?<=^TASK_DONE\s).+' "$OPT_STDOUT_FILE" 2>/dev/null | head -1 || true)"
        : "${_summary:=Agent completed}"
    else
        _status="FAILED"
        _summary="OpenCode emitted TASK_DONE but exited with code $pr_rc"
    fi
elif [ "$permission_blocked" -eq 1 ]; then
    _status="FAILED"
    _exit_code=1
    _summary="OpenCode permission policy rejected a tool call; the agent could not complete the task as instructed"
    [ -n "$error_message" ] && _summary+="; diagnostic=$error_message"
else
    step_limit_detected="false"
    if [ -s "$RAW_STDOUT_FILE" ]; then
        if grep -Eiq 'max(imum)?[[:space:]_-]+steps|steps?[[:space:]_-]+limit|step[[:space:]_-]+limit' "$RAW_STDOUT_FILE" 2>/dev/null; then
            step_limit_detected="true"
        fi
    fi

    if [ -n "$session_id" ] && [ "$step_limit_detected" = "true" ]; then
        # Only an explicit runtime step-limit condition is a continuation.
        # A normal step_finish(reason=stop) without TASK_DONE is a real protocol
        # failure and must not consume the same session three times.
        _status="NEEDS_CONTINUATION"
        _exit_code=1
        _summary="OpenCode reached its step limit without a completion marker; existing session can continue"
    elif [ "$pr_rc" -eq 0 ] && [ -n "$session_id" ]; then
        _status="FAILED"
        _exit_code=1
        _summary="OpenCode stopped without a completion marker; starting a fresh retry is required"
        error_type="RUNTIME_FAILURE"
    else
        _status="FAILED"
        if [ "$pr_rc" -eq 127 ]; then
            _summary="OpenCode binary not found"
        else
            _summary="OpenCode agent exited with code $pr_rc"
            [ -n "$error_type" ] && _summary+="; error_type=$error_type"
            [ -n "$error_message" ] && _summary+="; error=$error_message"
            [ -n "$error_source" ] && _summary+="; error_source=$error_source"
            _summary+="; duration_s=$duration"
            [ -n "$session_id" ] && _summary+="; session=$session_id"
            [ -n "$last_event_type" ] && _summary+="; last_event=$last_event_type"
        fi
    fi
fi
# Keep RAW_STDOUT_FILE; Manul task retention is responsible for cleanup.

# Derive a stable, machine-readable failure code from the classified status so
# the daemon and controller can act on the specific failure mode instead of only
# on the generic FAILED status.
failure_code=""
case "$_status" in
    FAILED)
        case "$error_type" in
            RUNTIME_PERMISSION_BLOCKED) failure_code="RUNTIME_PERMISSION_BLOCKED" ;;
            PermissionError)           failure_code="RUNTIME_PERMISSION_BLOCKED" ;;
            ProviderError)             failure_code="PROVIDER_ERROR" ;;
            *)                         failure_code="RUNTIME_FAILURE" ;;
        esac
        ;;
    TIMEOUT)            failure_code="RUNTIME_TIMEOUT" ;;
    BLOCKED)            failure_code="TASK_NEEDS_USER" ;;
    NEEDS_CONTINUATION) failure_code="NEEDS_CONTINUATION" ;;
    COMPLETED)          failure_code="" ;;
esac

jq -cn \
    --arg status "$_status" \
    --arg task_id "$OPT_TASK_ID" \
    --arg exit_code "$_exit_code" \
    --arg summary "$_summary" \
    --arg session_id "$session_id" \
    --arg duration_s "$duration" \
    --arg runtime "opencode" \
    --arg error_type "$error_type" \
    --arg error_message "$error_message" \
    --arg error_source "$error_source" \
    --arg last_event_type "$last_event_type" \
    --arg failure_code "$failure_code" \
    --arg raw_log "$RAW_STDOUT_FILE" \
    --arg permission_tool "$permission_tool" \
    --arg permission_operation "$permission_operation" \
    --arg selected_agent "$OPT_AGENT" \
    '{status:$status, task_id:$task_id, exit_code:($exit_code|tonumber), summary:$summary, session_id:$session_id, duration_s:($duration_s|tonumber), runtime:$runtime, failure_code:$failure_code, diagnostics:{error_type:$error_type,error_message:$error_message,error_source:$error_source,last_event_type:$last_event_type,permission_tool:$permission_tool,permission_operation:$permission_operation,selected_agent:$selected_agent,raw_log:$raw_log}}'

if [ "$_status" = "BLOCKED" ]; then
    exit 0
fi
exit "$_exit_code"
