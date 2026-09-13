#!/usr/bin/bash
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

# Run the orchestrator, appending output to the designated files
"$OPENCLAW_BIN" agent --agent main --message-file "$PROMPT_FILE" >>"$STDOUT_FILE" 2>>"$STDERR_FILE"
local rc=$?

if [ $rc -eq 0 ]; then
    echo "TASK_DONE" >>"$STDOUT_FILE"
else
    echo "TASK_FAILED: Orchestrator exited with non-zero status" >>"$STDOUT_FILE"
fi

exit $rc
