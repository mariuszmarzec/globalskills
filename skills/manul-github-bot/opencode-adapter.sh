#!/usr/bin/env bash
# opencode-adapter.sh — OpenCode runtime adapter for AgentExecutor.
#
# This adapter is an EQUALLY VALID backend alongside OpenClawAdapter.
# It does NOT import, delegate to, or depend on OpenClawAdapter or any
# OpenClaw-specific code. It must work correctly even when `openclaw` is
# absent from PATH.
#
# OpenCode uses persistent sessions natively. The adapter creates or reuses
# a session keyed by taskId, runs the agent prompt, and returns the
# runtime-neutral ExecutionResult.
#
# Session lifecycle:
#   • First call for a task → creates a new OpenCode session
#   • Subsequent calls with the same session_id → resumes that session
#   • If step limit reached without completion → NEEDS_CONTINUATION
#
# Exit-code semantics:
#   0  → COMPLETED      (agent finished the task; TASK_DONE should be in stdout)
#   127 → FAILED        (opencode binary not found)
#   124 → TIMEOUT       (timeout wrapper killed the process)
#   other non-zero → FAILED
#
# Usage (called by agent-executor.sh, not directly by the daemon):
#   opencode-adapter.sh \
#     --task-id <id> \
#     --prompt <path> \
#     --workspace <path> \
#     --agent <name> \
#     --attempt <n> \
#     --timeout <seconds> \
#     --session-id <id-or-empty> \
#     --stdout-file <path> \
#     --stderr-file <path>

MANUL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$MANUL_SCRIPT_DIR/manul-paths.sh"
source "$MANUL_SCRIPT_DIR/process-runner.sh"

# --- Parse arguments ---
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

if [ -z "$OPT_TASK_ID" ] || [ -z "$OPT_PROMPT" ]; then
    printf '{"status":"FAILED","task_id":"","exit_code":1,"summary":"Missing required args (task-id/prompt)","session_id":"","duration_s":0}'
    exit 1
fi

mkdir -p "$(dirname "$OPT_STDOUT_FILE")" "$(dirname "$OPT_STDERR_FILE")" 2>/dev/null || true

# --- Resolve OpenCode binary ---
_resolve_opencode_bin() {
    if [ -n "${OPENCODE_BIN:-}" ] && [ -x "$OPENCODE_BIN" ]; then
        printf '%s' "$OPENCODE_BIN"
        return 0
    fi
    local found
    found="$(command -v opencode 2>/dev/null || echo "")"
    if [ -n "$found" ] && [ -x "$found" ]; then
        printf '%s' "$found"
        return 0
    fi
    return 1
}

OPENCODE_BIN=""
OPENCODE_BIN="$(_resolve_opencode_bin)"
if [ -z "$OPENCODE_BIN" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":127,"summary":"OpenCode binary not found (opencode not on PATH)","session_id":"","duration_s":0}' "$OPT_TASK_ID"
    exit 127
fi
export OPENCODE_BIN

# --- Session resolution ---
# OpenCode sessions are identified by a stable key derived from the task.
# If a session_id was passed in (from a previous execution), reuse it.
# Otherwise derive a session key from the task id + attempt.
if [ -n "$OPT_SESSION_ID" ]; then
    SESSION_KEY="$OPT_SESSION_ID"
else
    SESSION_KEY="manul-${OPT_TASK_ID}-attempt-${OPT_ATTEMPT}"
fi
export SESSION_KEY

# --- Timeout ---
OPENCODE_AGENT_TIMEOUT="${MANUL_OPENCODE_AGENT_TIMEOUT:-43200}"
if ! [[ "$OPENCODE_AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$OPENCODE_AGENT_TIMEOUT" -lt 1 ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":2,"summary":"Invalid MANUL_OPENCODE_AGENT_TIMEOUT=%s","session_id":"","duration_s":0}' \
        "$OPT_TASK_ID" "$OPENCODE_AGENT_TIMEOUT"
    exit 2
fi

# --- Build environment for the invocation ---
export OPENCODE_BIN
export OPENCODE_AGENT_TIMEOUT
export MANUL_TASK_ID="$OPT_TASK_ID"
export MANUL_ATTEMPT="$OPT_ATTEMPT"
# workspace: let the agent know where it should work
export WORKSPACE="$OPT_WORKSPACE"
# Ensure skills path is visible
export OPENCODE_SKILLS_PATH="${OPENCODE_SKILLS_PATH:-$HOME/.agents/skills}"

# --- Launch ---
log() {
    echo "[$(date -Is)] opencode-adapter: $*" >>"$OPT_STDERR_FILE"
}

log "starting task=$OPT_TASK_ID session=$SESSION_KEY timeout=${OPENCODE_AGENT_TIMEOUT}s opencode=$OPENCODE_BIN prompt=$OPT_PROMPT workspace=$OPT_WORKSPACE"

# --- Execute with ProcessRunner boundary ---
# Adapters MUST NOT spawn subprocesses directly. ProcessRunner.run() enforces
# the hard timeout (124), is mockable in tests, and preserves caller-supplied
# stdout/stderr files so the daemon can inspect result markers afterwards.
# OpenCode reads the prompt from stdin, so we feed it via a here-doc through
# ProcessRunner's stdin redirection.
_run_opencode_agent() {
    # OpenCode uses --session for session persistence and --print for
    # structured output. The prompt is passed via stdin.
    "$OPENCODE_BIN" run \
        --session "$SESSION_KEY" \
        --print \
        --timeout "$OPENCODE_AGENT_TIMEOUT" \
        --working-dir "$OPT_WORKSPACE"
}

ProcessRunner_TmpStdout="$OPT_STDOUT_FILE"
ProcessRunner_TmpStderr="$OPT_STDERR_FILE"

_pr_result="$(ProcessRunner.run \
    --timeout "$OPENCODE_AGENT_TIMEOUT" \
    --cwd "$OPT_WORKSPACE" \
    -- "$OPENCODE_BIN" run \
        --session "$SESSION_KEY" \
        --print \
        --timeout "$OPENCODE_AGENT_TIMEOUT" \
        --working-dir "$OPT_WORKSPACE" <"$OPT_PROMPT")"
_pr_header="$(printf '%s\n' "$_pr_result" | head -1)"
_pr_rc="$(printf '%s' "$_pr_header" | cut -d'|' -f1)"
_pr_dur="$(printf '%s' "$_pr_header" | cut -d'|' -f2)"
_pr_int="$(printf '%s' "$_pr_header" | cut -d'|' -f3)"
_pr_to="$(printf '%s' "$_pr_header" | cut -d'|' -f4)"

# Fallback if ProcessRunner produced no header (e.g. a sourcing failure).
: "${_pr_rc:=127}"
: "${_pr_dur:=0}"
: "${_pr_int:=false}"
: "${_pr_to:=false}"

rc="$_pr_rc"
_duration="$_pr_dur"

log "exit code=$rc duration=${_duration}s session=$SESSION_KEY"

# --- Map exit code to ExecutionResult ---
_exit_code="$rc"
_status="COMPLETED"
_summary=""
_session_id="$SESSION_KEY"

if [ "$rc" -eq 0 ]; then
    _status="COMPLETED"
    if [ -f "$OPT_STDOUT_FILE" ] && grep -qE '^TASK_DONE' "$OPT_STDOUT_FILE" 2>/dev/null; then
        _summary="$(grep -oP '(?<=^TASK_DONE\s).+' "$OPT_STDOUT_FILE" 2>/dev/null | head -1 || echo "Agent completed")"
    else
        _summary="Agent exited 0 but no TASK_DONE marker found in stdout"
    fi
elif [ "$rc" -eq 127 ]; then
    _status="FAILED"
    _summary="OpenCode binary not found"
    _exit_code=127
elif [ "$rc" -eq 124 ]; then
    _status="TIMEOUT"
    _summary="Agent execution timed out after ${OPENCODE_AGENT_TIMEOUT}s"
    _exit_code=124
else
    _status="FAILED"
    _summary="OpenCode agent exited with code $rc"
    _exit_code="$rc"
fi

# Check for BLOCKED (user needs input) or NEEDS_CONTINUATION in stdout
if [ -f "$OPT_STDOUT_FILE" ]; then
    if grep -qE '^TASK_NEEDS_USER_BEGIN' "$OPT_STDOUT_FILE" 2>/dev/null; then
        _status="BLOCKED"
        _summary="Agent needs user input"
    fi
fi

printf '{"status":"%s","task_id":"%s","exit_code":%s,"summary":"%s","session_id":"%s","duration_s":%s}\n' \
    "$_status" "$OPT_TASK_ID" "$_exit_code" "$_summary" "$_session_id" "$_duration"

exit "$_exit_code"
