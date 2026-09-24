#!/bin/bash
# manul-status.sh - Query task status from the Manul queue
#
# Usage:
#   manul-status.sh [OPTIONS] [TASK_ID]
#
# Options:
#   --task ID        Task/comment ID to query (required if no positional arg)
#   --json           Output JSON format
#   --list           List active tasks plus recent terminal tasks
#   --history        List terminal task history retained for the longer window
#   --status S       Filter by status (queued, running, blocked_user, completed, failed, stale)
#   --log            Show daemon.log instead of task status
#   --tail N         Number of log lines to show (default: 100)
#   --tail=N         Same as --tail N
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
#   manul-status.sh --history --json
#   manul-status.sh --log --tail=200
#
# JSON Output Schema:
#   {
#     "taskId": "string",
#     "conversationId": "string",
#     "status": "queued|running|completed|failed|stale",
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
MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
OUTPUT_FORMAT="text"
LIST_MODE=false
FILTER_STATUS=""
TASK_ID=""
LOG_MODE=false
HISTORY_MODE=false
LOG_TAIL=100

TASK_RETENTION_DEFAULT_LIST_DAYS=7
TASK_RETENTION_DEFAULT_HISTORY_DAYS=14
TASK_LIST_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_LIST_DAYS"
TASK_HISTORY_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_HISTORY_DAYS"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --task)
      [ $# -ge 2 ] || { echo "Error: --task requires an ID" >&2; exit 1; }
      TASK_ID="$2"; shift 2 ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    --list) LIST_MODE=true; shift ;;
    --history) HISTORY_MODE=true; LIST_MODE=true; shift ;;
    --status)
      [ $# -ge 2 ] || { echo "Error: --status requires a value" >&2; exit 1; }
      FILTER_STATUS="$2"; shift 2 ;;
    --log) LOG_MODE=true; shift ;;
    --tail)
      [ $# -ge 2 ] || { echo "Error: --tail requires a number" >&2; exit 1; }
      LOG_TAIL="$2"; shift 2 ;;
    --tail=*) LOG_TAIL="${1#--tail=}"; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) TASK_ID="$1"; shift ;;
  esac
done

if ! [[ "$LOG_TAIL" =~ ^[0-9]+$ ]] || [ "$LOG_TAIL" -lt 1 ]; then
  echo "Error: --tail must be a positive integer" >&2
  exit 1
fi

if [ "$LOG_MODE" = true ]; then
  LOG_FILE="$MANUL_DIR/daemon.log"
  if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Manul daemon log not found at $LOG_FILE" >&2
    exit 1
  fi
  tail -n "$LOG_TAIL" "$LOG_FILE"
  exit 0
fi

# Ensure database exists
if [ ! -f "$DB" ]; then
  echo "Error: Manul database not found at $DB" >&2
  exit 1
fi

# Escape strings for SQL
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}
load_task_retention() {
  local list_days history_days
  list_days="$(jq -r '.retention.listDays // empty' "$MANUL_DIR/config.json" 2>/dev/null || true)"
  history_days="$(jq -r '.retention.historyDays // empty' "$MANUL_DIR/config.json" 2>/dev/null || true)"

  if ! [[ "$list_days" =~ ^[0-9]+$ ]] || [ "$list_days" -lt 1 ] || \
     ! [[ "$history_days" =~ ^[0-9]+$ ]] || [ "$history_days" -lt 1 ] || \
     [ "$history_days" -lt $((list_days * 2)) ]; then
    TASK_LIST_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_LIST_DAYS"
    TASK_HISTORY_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_HISTORY_DAYS"
  else
    TASK_LIST_RETENTION_DAYS="$list_days"
    TASK_HISTORY_RETENTION_DAYS="$history_days"
  fi
}


if [ "$LIST_MODE" = true ]; then
  # List mode: query multiple tasks
  # Active tasks are always shown, including blocked_user tasks. Terminal tasks
  # are limited by the configured retention window. --history uses the longer window.
  load_task_retention
  local_retention_days="$TASK_LIST_RETENTION_DAYS"
  if [ "$HISTORY_MODE" = true ]; then
    local_retention_days="$TASK_HISTORY_RETENTION_DAYS"
  fi

  if [ -n "$FILTER_STATUS" ]; then
    if [ "$FILTER_STATUS" = "queued" ] || [ "$FILTER_STATUS" = "running" ] || [ "$FILTER_STATUS" = "blocked_user" ]; then
      WHERE_CLAUSE="WHERE status='$(sql_escape "$FILTER_STATUS")'"
    else
      WHERE_CLAUSE="WHERE status='$(sql_escape "$FILTER_STATUS")' AND COALESCE(processedAt, createdAt) >= datetime('now', '-$local_retention_days days')"
    fi
  elif [ "$HISTORY_MODE" = true ]; then
    WHERE_CLAUSE="WHERE status IN ('completed', 'failed', 'stale') AND COALESCE(processedAt, createdAt) >= datetime('now', '-$local_retention_days days')"
  else
    WHERE_CLAUSE="WHERE (status IN ('queued', 'running', 'blocked_user') OR (status IN ('completed', 'failed', 'stale') AND COALESCE(processedAt, createdAt) >= datetime('now', '-$local_retention_days days')))"
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
