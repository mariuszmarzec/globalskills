#!/bin/bash
# manul-agent-wrapper.sh - Wrapper to ensure TASK_DONE is emitted by the agent
#
# Usage: manul-agent-wrapper.sh <prompt-file> <stdout-file> <stderr-file>
#
# Runs the OpenClaw orchestrator with the given prompt, then appends
# TASK_DONE (if exit code 0) or TASK_FAILED (if exit code non-zero) to the stdout file.
# The orchestrator's stdout and stderr are appended to the respective files.

set -uo pipefail

if [ $# -ne 3 ]; then
    echo "Usage: $0 <prompt-file> <stdout-file> <stderr-file>" >&2
    exit 1
fi

PROMPT_FILE="$1"
STDOUT_FILE="$2"
STDERR_FILE="$3"

# Flag to track if we're receiving a termination signal
TERMINATING=0

# Function to clean up on exit
cleanup() {
    if [ "$TERMINATING" -eq 0 ]; then
        TERMINATING=1
        if [ -n "${ORCHESTRATOR_PID:-}" ] && kill -0 "$ORCHESTRATOR_PID" 2>/dev/null; then
            kill -TERM "$ORCHESTRATOR_PID" 2>/dev/null || true
            wait "$ORCHESTRATOR_PID" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT INT TERM

# Run the orchestrator in the background
"$OPENCLAW_BIN" agent --agent main --message-file "$PROMPT_FILE" >>"$STDOUT_FILE" 2>>"$STDERR_FILE" &
ORCHESTRATOR_PID=$!
wait "$ORCHESTRATOR_PID"
rc=$?

# If we were interrupted by a signal, don't emit TASK_DONE/TASK_FAILED
if [ "$TERMINATING" -eq 1 ]; then
    log "WARNING: Agent wrapper interrupted by signal, not emitting task status"
    exit 1
fi

if [ $rc -eq 0 ]; then
    echo "TASK_DONE" >>"$STDOUT_FILE"
else
    echo "TASK_FAILED: Orchestrator exited with non-zero status" >>"$STDOUT_FILE"
fi

exit $rc

