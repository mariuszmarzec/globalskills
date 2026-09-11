#!/bin/bash
# manul-wait.sh - Wait for a task to complete
#
# Usage:
#   manul-wait.sh [OPTIONS] TASK_ID
#
# Options:
#   --timeout SECONDS  Maximum time to wait (default: 300)
#   --interval SECONDS Polling interval (default: 5)
#   --json             Output JSON format
#   --follow           Follow mode: print status updates as they happen
#
# Returns:
#   Final task result in JSON format
#   Exit code 0 on successful completion
#   Exit code 1 on failure or timeout
#
# Examples:
#   manul-wait.sh cli-abc123
#   manul-wait.sh --timeout 600 --json cli-abc123
#   manul-wait.sh --follow cli-abc123

set -euo pipefail

# Configuration
MANUL_DIR="${MANUL_DIR:-${OPENCLAW_MANUL_DIR:-$HOME/.openclaw/manul}}"
DB="$MANUL_DIR/manul.db"
TIMEOUT=300
INTERVAL=5
OUTPUT_FORMAT="text"
FOLLOW_MODE=false
TASK_ID="${1:-}"

# Parse options
while [[ $# -gt 0 ]]; do
  case $1 in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    --follow) FOLLOW_MODE=true; shift ;;
    *) TASK_ID="$1"; shift ;;
  esac
done

# Validate required argument
if [ -z "$TASK_ID" ]; then
  echo "Error: TASK_ID is required" >&2
  echo "Usage: manul-wait.sh [OPTIONS] TASK_ID" >&2
  exit 1
fi

# Ensure database exists
if [ ! -f "$DB" ]; then
  echo "Error: Manul database not found at $DB" >&2
  exit 1
fi

# Track elapsed time
START_TIME=$(date +%s)
END_TIME=$((START_TIME + TIMEOUT))

# Store task_id for later use
_STORED_TASK_ID="$TASK_ID"

while true; do
  CURRENT_TIME=$(date +%s)

  # Check timeout
  if [ "$CURRENT_TIME" -ge "$END_TIME" ]; then
    if [ "$OUTPUT_FORMAT" = "json" ]; then
      printf '{"error": "Timeout", "taskId": "%s", "timeoutSeconds": %s}\n' "$TASK_ID" "$TIMEOUT"
    else
      echo "Error: Timeout waiting for task '$TASK_ID'" >&2
    fi
    exit 1
  fi

  # Query task status directly (no sourcing to avoid stdout pollution)
  STATUS="$(sqlite3 "$DB" "SELECT status, processedAt FROM processed_comments WHERE commentId='$TASK_ID';" 2>/dev/null)" || {
    echo "Error: Failed to query task status" >&2
    exit 1
  }

  if [ -z "$STATUS" ]; then
    if [ "$OUTPUT_FORMAT" = "json" ]; then
      printf '{"error": "Task not found", "taskId": "%s"}\n' "$TASK_ID"
    else
      echo "Error: Task '$TASK_ID' not found" >&2
    fi
    exit 1
  fi

  IFS='|' read -r status completed_at <<< "$STATUS"

  if [ "$FOLLOW_MODE" = true ]; then
    echo "Status: $status" >&2
  fi

  # Check if task is complete
  if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
    if [ "$FOLLOW_MODE" = true ]; then
      echo "Task $status" >&2
    fi

    # Return final result by querying directly
    RESULT="$(sqlite3 "$DB" "
      SELECT commentId, status, COALESCE(resultSummary, context) as summary_data, processedAt, attempts
      FROM processed_comments
      WHERE commentId='$TASK_ID';" 2>/dev/null)"

    if [ "$OUTPUT_FORMAT" = "json" ]; then
      IFS='|' read -r rid rstatus rsummary rcompleted rattempts <<< "$RESULT"
      if [ "$rstatus" = "completed" ]; then
        printf '{"taskId": "%s", "status": "%s", "success": true, "summary": "%s", "completedAt": "%s", "attempts": %s}\n' \
          "$TASK_ID" "$rstatus" "$(printf '%s' "$rsummary" | sed 's/"/\\"/g')" "${rcompleted:-}" "${rattempts:-0}"
      else
        printf '{"taskId": "%s", "status": "%s", "success": false, "error": "%s", "completedAt": "%s", "attempts": %s}\n' \
          "$TASK_ID" "$rstatus" "$(printf '%s' "$rsummary" | sed 's/"/\\"/g')" "${rcompleted:-}" "${rattempts:-0}"
      fi
    else
      echo "Task $status"
      if [ "$status" = "completed" ]; then
        echo "Summary: ${rsummary:-Done}"
      else
        echo "Error: ${rsummary:-Unknown}"
      fi
    fi
    exit 0
  fi

  # Task still pending/running, wait and poll again
  sleep "$INTERVAL"
done
