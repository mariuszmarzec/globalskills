#!/bin/bash
# manul-status.sh - Query task status from the Manul queue
#
# Usage:
#   manul-status.sh [OPTIONS] [TASK_ID]
#
# Options:
#   --task ID        Task/comment ID to query (required if no positional arg)
#   --json           Output JSON format
#   --list           List all tasks (optional filter by status)
#   --status S       Filter by status (queued, running, completed, failed)
#
# Returns:
#   JSON with task details or list of tasks
#   Exit code 0 on success, 1 on failure
#
# Examples:
#   manul-status.sh cli-abc123
#   manul-status.sh --task cli-abc123 --json
#   manul-status.sh --list --status queued
#   manul-status.sh --list --json
#
# JSON Output Schema:
#   {
#     "taskId": "string",
#     "conversationId": "string",
#     "status": "queued|running|completed|failed",
#     "repo": "string",
#     "issue": number,
#     "attempts": number,
#     "createdAt": "ISO8601",
#     "startedAt": "ISO8601|null",
#     "completedAt": "ISO8601|null",
#     "workerId": "number|null",
#     "workspaceId": "string|null",
#     "nextAttemptAt": "ISO8601|null",
#     "prompt": "string"
#   }

set -euo pipefail

# Configuration
MANUL_DIR="${MANUL_DIR:-${OPENCLAW_MANUL_DIR:-$HOME/.openclaw/manul}}"
DB="$MANUL_DIR/manul.db"
OUTPUT_FORMAT="text"
LIST_MODE=false
FILTER_STATUS=""
TASK_ID=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK_ID="$2"; shift 2 ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    --list) LIST_MODE=true; shift ;;
    --status) FILTER_STATUS="$2"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) TASK_ID="$1"; shift ;;
  esac
done

# Ensure database exists
if [ ! -f "$DB" ]; then
  echo "Error: Manul database not found at $DB" >&2
  exit 1
fi

# Escape strings for SQL
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

if [ "$LIST_MODE" = true ]; then
  # List mode: query multiple tasks
  WHERE_CLAUSE=""
  if [ -n "$FILTER_STATUS" ]; then
    WHERE_CLAUSE="WHERE status='$(sql_escape "$FILTER_STATUS")'"
  fi

  RESULTS="$(sqlite3 "$DB" "
    SELECT commentId, repository, issueNumber, status, conversationId, 
           attempts, createdAt, processedAt, workerPid, workspaceId, nextAttemptAt
    FROM processed_comments $WHERE_CLAUSE
    ORDER BY createdAt DESC
    LIMIT 100;
  " 2>/dev/null)" || {
    echo "Error: Failed to query task status" >&2
    exit 1
  }

  if [ -z "$RESULTS" ]; then
    if [ "$OUTPUT_FORMAT" = "json" ]; then
      echo "[]"
    else
      echo "No tasks found"
    fi
    exit 0
  fi

  if [ "$OUTPUT_FORMAT" = "json" ]; then
    echo "["
    FIRST=true
    while IFS='|' read -r tid repo issue status conv attempts created started worker ws next; do
      if [ "$FIRST" = true ]; then
        FIRST=false
      else
        echo ","
      fi
      # Convert null values
      [ -z "$started" ] && started="null" || started="\"$started\""
      [ -z "$worker" ] && worker="null" || worker="$worker"
      [ -z "$ws" ] && ws="null" || ws="\"$ws\""
      [ -z "$next" ] && next="null" || next="\"$next\""
      
      printf '  {"taskId": "%s", "repo": "%s", "issue": %s, "status": "%s", "conversationId": "%s", "attempts": %s, "createdAt": "%s", "startedAt": %s, "workerId": %s, "workspaceId": %s, "nextAttemptAt": %s}' \
        "$tid" "$repo" "$issue" "$status" "$conv" "$attempts" "$created" "$started" "$worker" "$ws" "$next"
    done <<< "$RESULTS"
    echo ""
    echo "]"
  else
    printf "%-40s %-20s %-8s %-10s %s\n" "TASK_ID" "REPO#ISSUE" "STATUS" "ATTEMPTS" "CREATED"
    printf "%-40s %-20s %-8s %-10s %s\n" "-------" "----------" "------" "--------" "-------"
    while IFS='|' read -r tid repo issue status conv attempts created started worker ws next; do
      printf "%-40s %-20s %-8s %-10s %s\n" "$tid" "${repo}#${issue}" "$status" "$attempts" "$created"
    done <<< "$RESULTS"
  fi
else
  # Single task mode
  if [ -z "$TASK_ID" ]; then
    echo "Error: TASK_ID is required (use --list to see all tasks)" >&2
    exit 1
  fi

  ESCAPED_TASK_ID="$(sql_escape "$TASK_ID")"
  
  RESULT="$(sqlite3 "$DB" "
    SELECT commentId, repository, issueNumber, status, conversationId,
           parentTaskId, agent, attempts, createdAt, processedAt,
           workerPid, workspaceId, nextAttemptAt, prompt
    FROM processed_comments
    WHERE commentId='$ESCAPED_TASK_ID';
  " 2>/dev/null)" || {
    echo "Error: Failed to query task status" >&2
    exit 1
  }

  if [ -z "$RESULT" ]; then
    if [ "$OUTPUT_FORMAT" = "json" ]; then
      printf '{"error": "Task not found", "taskId": "%s"}\n' "$TASK_ID"
    else
      echo "Error: Task '$TASK_ID' not found" >&2
    fi
    exit 1
  fi

  IFS='|' read -r tid repo issue status conv parent agent attempts created started worker ws next prompt <<< "$RESULT"

  if [ "$OUTPUT_FORMAT" = "json" ]; then
    # Build JSON output
    JSON="{\"taskId\": \"$tid\""
    JSON+=", \"conversationId\": \"$conv\""
    JSON+=", \"status\": \"$status\""
    JSON+=", \"repo\": \"$repo\""
    JSON+=", \"issue\": $issue"
    [ -n "$agent" ] && JSON+=", \"agent\": \"$agent\""
    [ -n "$parent" ] && JSON+=", \"parentTaskId\": \"$parent\""
    JSON+=", \"attempts\": ${attempts:-0}"
    JSON+=", \"createdAt\": \"$created\""
    
    # Optional fields
    [ -n "$started" ] && JSON+=", \"startedAt\": \"$started\""
    [ -n "$worker" ] && JSON+=", \"workerId\": $worker"
    [ -n "$ws" ] && JSON+=", \"workspaceId\": \"$ws\""
    [ -n "$next" ] && JSON+=", \"nextAttemptAt\": \"$next\""
    [ -n "$prompt" ] && JSON+=", \"prompt\": \"$(echo "$prompt" | sed 's/"/\\"/g')\""
    
    JSON+="}"
    echo "$JSON"
  else
    echo "Task Status:"
    echo "  taskId:         $tid"
    echo "  conversationId: $conv"
    echo "  status:         $status"
    echo "  repo:           $repo#$issue"
    [ -n "$agent" ] && echo "  agent:          $agent"
    [ -n "$parent" ] && echo "  parentTaskId:   $parent"
    echo "  attempts:       ${attempts:-0}"
    echo "  createdAt:      ${created:-}"
    [ -n "$started" ] && echo "  startedAt:      $started"
    [ -n "$worker" ] && echo "  workerId:       $worker"
    [ -n "$ws" ] && echo "  workspaceId:    $ws"
    [ -n "$next" ] && echo "  nextAttemptAt:  $next"
  fi
fi

exit 0
