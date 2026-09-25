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
SESSION_ARGS=()
if [ -n "$OPT_SESSION_ID" ]; then
    SESSION_ARGS=(--session "$OPT_SESSION_ID")
fi
AGENT_ARGS=()
if [ -n "$OPT_AGENT" ]; then
    AGENT_ARGS=(--agent "$OPT_AGENT")
fi

RAW_STDOUT_FILE="${OPT_STDOUT_FILE}.opencode.jsonl"
rm -f "$RAW_STDOUT_FILE" 2>/dev/null || true
mkdir -p "$(dirname "$OPT_STDOUT_FILE")" "$(dirname "$OPT_STDERR_FILE")" 2>/dev/null || true

log() {
    echo "[$(date -Is)] opencode-adapter: $*" >>"$OPT_STDERR_FILE"
}
log "starting task=$OPT_TASK_ID attempt=$OPT_ATTEMPT session=${OPT_SESSION_ID:-<new>} timeout=${AGENT_TIMEOUT}s opencode=$OPENCODE_BIN workspace=$OPT_WORKSPACE"

# ProcessRunner is the only process boundary. The raw JSONL is temporary;
# OPT_STDOUT_FILE is rewritten below into plain agent text/control markers.
ProcessRunner_TmpStdout="$RAW_STDOUT_FILE"
ProcessRunner_TmpStderr="$OPT_STDERR_FILE"

ProcessRunner.run \
    --timeout "$AGENT_TIMEOUT" \
    --cwd "$OPT_WORKSPACE" \
    -- "$OPENCODE_BIN" run \
        "${SESSION_ARGS[@]}" \
        "${AGENT_ARGS[@]}" \
        --format json \
        --dir "$OPT_WORKSPACE" \
        "$PROMPT_CONTENT"
pr_rc=$?

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
elif [ -n "$session_id" ] && (
    grep -Eiq 'max(imum)?[[:space:]_-]+steps|steps?[[:space:]_-]+limit|step[[:space:]_-]+limit' "$RAW_STDOUT_FILE" 2>/dev/null ||
    { [ "$pr_rc" -eq 0 ] && ! grep -qE '^TASK_(DONE|FAILED|NEEDS_USER_BEGIN)([[:space:]:]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; }
); then
    # OpenCode may finish its allowed step budget with a normal process exit.
    # Without a Manul completion marker the task is not logically complete, so
    # retain the session for a continuation execution.
    _status="NEEDS_CONTINUATION"
    _exit_code=1
    _summary="OpenCode did not emit a completion marker; existing session can continue"
else
    _status="FAILED"
    if [ "$pr_rc" -eq 127 ]; then
        _summary="OpenCode binary not found"
    else
        _summary="OpenCode agent exited with code $pr_rc"
    fi
fi

rm -f "$RAW_STDOUT_FILE" 2>/dev/null || true

jq -cn \
    --arg status "$_status" \
    --arg task_id "$OPT_TASK_ID" \
    --arg exit_code "$_exit_code" \
    --arg summary "$_summary" \
    --arg session_id "$session_id" \
    --arg duration_s "$duration" \
    '{status:$status, task_id:$task_id, exit_code:($exit_code|tonumber), summary:$summary, session_id:$session_id, duration_s:($duration_s|tonumber)}'

if [ "$_status" = "BLOCKED" ]; then
    exit 0
fi
exit "$_exit_code"
