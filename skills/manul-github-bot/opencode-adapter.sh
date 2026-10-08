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

_resolve_opencode_bin() {
    if [ -n "${OPENCODE_BIN:-}" ] && [ -x "$OPENCODE_BIN" ]; then
        printf '%s' "$OPENCODE_BIN"
        return 0
    fi
    command -v opencode 2>/dev/null || true
}
OPENCODE_BIN="$(_resolve_opencode_bin)"
if [ -z "$OPENCODE_BIN" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":127,"summary":"OpenCode binary not found (opencode not on PATH)","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 127
fi
export OPENCODE_BIN

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
log "starting task=$OPT_TASK_ID attempt=$OPT_ATTEMPT session=${OPT_SESSION_ID:-<new>} timeout=${AGENT_TIMEOUT}s opencode=$OPENCODE_BIN workspace=$OPT_WORKSPACE"

# ProcessRunner is the only process boundary. The raw JSONL is retained as a
# per-attempt diagnostic artifact; OPT_STDOUT_FILE is rewritten below into plain
# agent text/control markers.
ProcessRunner_TmpStdout="$RAW_STDOUT_FILE"
ProcessRunner_TmpStderr="$OPT_STDERR_FILE"

# Capture ProcessRunner output so its protocol line cannot leak into the
# adapter stdout. AgentExecutor/AgentExecutionController expect stdout to
# contain exactly one final ExecutionResult JSON document.
local_runner_result="$(ProcessRunner.run \
    --timeout "$AGENT_TIMEOUT" \
    --cwd "$OPT_WORKSPACE" \
    -- "$OPENCODE_BIN" run \
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
# missing from JSONL even though the session completes. Preserve markers that
# are visibly present in raw events so Manul's existing lifecycle verifier
# cannot silently miss a completion signal.
for marker in TASK_DONE TASK_FAILED TASK_NEEDS_USER_BEGIN TASK_NEEDS_USER_END; do
    if ! grep -qE "^${marker}($|[[:space:]:])" "$OPT_STDOUT_FILE" 2>/dev/null \
       && grep -q "${marker}" "$RAW_STDOUT_FILE" 2>/dev/null; then
        printf '%s\n' "${marker}" >>"$OPT_STDOUT_FILE"
    fi
done

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
if [ -s "$RAW_STDOUT_FILE" ]; then
    if jq -e 'select(.type == "tool_use") | select(.part.state.status == "error") | select(.part.state.error | test("permission|rejected|auto-reject"; "i"))' "$RAW_STDOUT_FILE" >/dev/null 2>&1; then
        permission_blocked=1
    fi
fi
# Stderr permission detection is a fallback only. When the runtime already
# emitted a structured JSONL error event (e.g. ProviderError), that takes
# precedence so incidental permission text in stderr does not override the
# stronger structured diagnostic.
if [ "$permission_blocked" -eq 0 ] && [ -z "$error_message" ] && [ -s "$OPT_STDERR_FILE" ]; then
    if grep -Eqi 'permission requested: [^;]+; auto-rejecting' "$OPT_STDERR_FILE" 2>/dev/null; then
        permission_blocked=1
    fi
fi
if [ "$permission_blocked" -eq 1 ]; then
    error_type="RUNTIME_PERMISSION_BLOCKED"
    error_source="runtime_jsonl"
    if [ -z "$error_message" ]; then
        error_message="OpenCode tool call rejected by runtime permission policy"
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
    _summary="OpenCode tool call was rejected by the runtime permission policy; the agent could not complete the task as instructed"
else
    local step_limit_detected="false"
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
    '{status:$status, task_id:$task_id, exit_code:($exit_code|tonumber), summary:$summary, session_id:$session_id, duration_s:($duration_s|tonumber), runtime:$runtime, failure_code:$failure_code, diagnostics:{error_type:$error_type,error_message:$error_message,error_source:$error_source,last_event_type:$last_event_type,raw_log:$raw_log}}'

if [ "$_status" = "BLOCKED" ]; then
    exit 0
fi
exit "$_exit_code"
