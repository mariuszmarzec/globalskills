#!/usr/bin/env bash
# agent-execution-controller.sh — Thin lifecycle controller for agent execution.
#
# This layer sits between the daemon and AgentExecutor. It owns:
#   • timeout enforcement (outer watchdog + inner adapter timeout)
#   • interruption / cancellation support
#   • continuation of an existing session (session_id forwarded to adapter)
#   • interpretation of ExecutionResult into daemon-state transitions
#
# The controller does NOT implement an LLM/tool loop — that belongs to each
# adapter and its underlying runtime.
#
# Public API:
#   AgentExecutionController.execute <context_json_file>
#     → writes ExecutionResult JSON to stdout
#
# Public API:
#   AgentExecutionController.continue_session <context_json_file> <session_id>
#     → like execute but sets session_id in context and sets continuation=true
#
# Mapping from ExecutionResult.status to daemon action:
#   COMPLETED        → transition task to completed
#   FAILED           → transition task to failed (or retry, see max_attempts)
#   TIMEOUT          → treat as FAILED (same daemon path)
#   INTERRUPTED      → requeue for retry (same as recovery)
#   BLOCKED          → transition to blocked_user
#   NEEDS_CONTINUATION → requeue with same session_id (same logical task)
#
# The controller adds a small grace window: if the adapter times out but the
# result file already contains TASK_DONE, the daemon should prefer the result
# file over the raw timeout signal.

MANUL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$MANUL_SCRIPT_DIR/manul-paths.sh"
source "$MANUL_SCRIPT_DIR/agent-executor.sh"

AgentExecutionController_ExitCode=0
AgentExecutionController_SessionId=""

AgentExecutionController.execute() {
    local ctx_file="$1"
    if [ -z "$ctx_file" ] || [ ! -f "$ctx_file" ]; then
        printf '{"status":"FAILED","task_id":"","exit_code":1,"summary":"Missing or unreadable execution context file","session_id":"","duration_s":0}\n'
        AgentExecutionController_ExitCode=1
        AgentExecutionController_SessionId=""
        return 1
    fi

    local task_id timeout max_wait_grace
    task_id="$(jq -r '.taskId // ""' "$ctx_file" 2>/dev/null)"
    timeout="$(jq -r '.timeout // 0' "$ctx_file" 2>/dev/null)"
    max_wait_grace=60  # seconds to wait for result file after adapter returns

    AgentExecutionController_SessionId=""

    # Delegate to AgentExecutor
    local result
    result="$(AgentExecutor.execute "$ctx_file")"
    local rc=$?

    if [ $rc -ne 0 ] && [ -z "$result" ]; then
        # Adapter crashed before producing structured output — fabricate FAILED.
        result="$(printf '{"status":"FAILED","task_id":"%s","exit_code":%d,"summary":"Adapter process exited with code %d","session_id":"","duration_s":0}' \
            "$task_id" "$rc" "$rc")"
    fi

    # If adapter reported a timeout but the result file already has TASK_DONE,
    # override to COMPLETED (daemon verifies result file, not just exit code).
    local status
    status="$(printf '%s' "$result" | jq -r '.status // "FAILED"' 2>/dev/null)"
    local exit_code
    exit_code="$(printf '%s' "$result" | jq -r '.exit_code // 1' 2>/dev/null)"
    local session_id
    session_id="$(printf '%s' "$result" | jq -r '.session_id // ""' 2>/dev/null)"

    if [ "$status" = "TIMEOUT" ] || { [ "$exit_code" -eq 124 ] 2>/dev/null && [ "$status" != "COMPLETED" ]; }; then
        # Check if TASK_DONE was already emitted before the timeout killed us.
        local stdout_file
        stdout_file="$(printf '%s' "$result" | jq -r '.session_id // empty' 2>/dev/null)"
        # We don't have stdout_file here; use ctx_file to derive.
        local prompt_file
        prompt_file="$(jq -r '.prompt // ""' "$ctx_file" 2>/dev/null)"
        local check_file="${MANUL_TASKS_DIR:-$MANUL_DIR/tasks}/task-${task_id}.stdout"
        if [ -f "$check_file" ] && grep -qE '^TASK_DONE' "$check_file" 2>/dev/null; then
            # The agent posted TASK_DONE before the outer timeout — treat as success.
            result="$(printf '%s' "$result" | jq -c '. + {status: "COMPLETED", exit_code: 0, summary: "Completed despite timeout wrapper (TASK_DONE already present)"}')"
            AgentExecutionController_SessionId="$session_id"
        elif [ "$status" = "TIMEOUT" ] && [ -n "$session_id" ]; then
            # Time out mid-session but session exists — surface NEEDS_CONTINUATION.
            result="$(printf '%s' "$result" | jq -c '. + {status: "NEEDS_CONTINUATION", summary: (.summary + " (session continue possible)")}')"
            AgentExecutionController_SessionId="$session_id"
        else
            AgentExecutionController_SessionId=""
        fi
    else
        AgentExecutionController_SessionId="$session_id"
    fi

    printf '%s\n' "$result"
    AgentExecutionController_ExitCode="$rc"
    return "$rc"
}

AgentExecutionController.continue_session() {
    local ctx_file="$1"
    local session_id="$2"
    if [ -z "$ctx_file" ] || [ ! -f "$ctx_file" ]; then
        printf '{"status":"FAILED","task_id":"","exit_code":1,"summary":"Missing context file for session continuation","session_id":"","duration_s":0}\n'
        AgentExecutionController_ExitCode=1
        AgentExecutionController_SessionId=""
        return 1
    fi
    # Inject session_id and continuation flag into context
    local modified_ctx
    modified_ctx="$(printf '%s' "$(cat "$ctx_file")" | jq -c \
        --arg sid "$session_id" \
        '. + {session_id: $sid, continuation: true}')"
    local tmp_ctx
    tmp_ctx="$(mktemp "${MANUL_TASKS_DIR:-$MANUL_DIR/tasks}/ctx-XXXXXX.json")"
    printf '%s\n' "$modified_ctx" > "$tmp_ctx"
    local result
    result="$(AgentExecutionController.execute "$tmp_ctx")"
    local rc=$?
    rm -f "$tmp_ctx" 2>/dev/null || true
    printf '%s\n' "$result"
    AgentExecutionController_ExitCode="$rc"
    return "$rc"
}

# Allow sourcing for testing
if [ "${1:-}" = "--test" ]; then
    echo "AgentExecutionController loaded successfully"
fi
