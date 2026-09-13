#!/bin/bash
# manul-conversation.sh - External orchestration CLI for Manul conversation lifecycle
#
# This script provides a machine-readable contract for external orchestrators
# (e.g., ChatGPT) to drive Manul through a persistent GitHub Issue/PR conversation.
#
# Usage:
#   manul-conversation create    --repo REPO --title TITLE --prompt PROMPT [--json]
#   manul-conversation submit    --conversation-id ID --prompt PROMPT [--action ACTION] [--parent-task-id ID] [--pr-number N] [--json]
#   manul-conversation status    --conversation-id ID [--json]
#   manul-conversation result    --task-id ID [--json]
#   manul-conversation close    --conversation-id ID [--json]
#
# JSON stdout contains ONLY JSON. Errors go to stderr.
# Exit codes: 0=success, 1=failure, 2=not found, 3=bad request

set -euo pipefail

MANUL_DIR="${MANUL_DIR:-${OPENCLAW_MANUL_DIR:-$HOME/.openclaw/manul}}"
DB="${MANUL_DIR}/manul.db"
CONFIG="${MANUL_DIR}/config.json"
POLL="${MANUL_DIR}/poll.sh"
FEEDBACK="${MANUL_DIR}/feedback.sh"

# Ensure DB path is on native ext4
if [[ "$DB" == /mnt/f/* ]]; then
  DB="/home/marzec/.openclaw/manul/manul.db"
fi

# JSON output flag
JSON_OUTPUT=false

# Parse global options
ACTION=""
REPO=""
TITLE=""
PROMPT=""
CONVERSATION_ID=""
TASK_ID=""
AGENT=""
PARENT_TASK_ID=""
PR_NUMBER=""
ACTION_TYPE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --conversation-id) CONVERSATION_ID="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --parent-task-id) PARENT_TASK_ID="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --action) ACTION_TYPE="$2"; shift 2 ;;
    create|status|submit|result|close) ACTION="$1"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 3 ;;
  esac
done

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

error_exit() {
  local msg="$1"
  local code="${2:-1}"
  if [ "$JSON_OUTPUT" = true ]; then
    echo "{\"error\": $(printf '%s' "$msg" | jq -Rs .), \"code\": $code}" >&2
  else
    echo "ERROR: $msg" >&2
  fi
  exit "$code"
}

init_schema() {
  mkdir -p "$(dirname "$DB")"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments (
    commentId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    commentUrl TEXT NOT NULL,
    author TEXT,
    agent TEXT,
    prompt TEXT NOT NULL,
    context TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT,
    processedAt TEXT,
    heartbeatAt TEXT,
    leaseExpiresAt TEXT,
    workerPid INTEGER,
    nextAttemptAt TEXT,
    conversationId TEXT,
    parentTaskId TEXT,
    workspaceId TEXT,
    action TEXT DEFAULT 'IMPLEMENT',
    prNumber INTEGER,
    prUrl TEXT
  );"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversations (
    conversationId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    issueUrl TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'OPEN',
    activeTaskId TEXT,
    activePrNumber TEXT,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
  );"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);"
  if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|action|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN action TEXT DEFAULT 'IMPLEMENT';" 2>/dev/null || true
  fi
  if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|prNumber|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER;" 2>/dev/null || true
  fi
  if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|prUrl|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN prUrl TEXT;" 2>/dev/null || true
  fi
}

cmd_create() {
  if [ -z "$REPO" ] || [ -z "$TITLE" ] || [ -z "$PROMPT" ]; then
    error_exit "create requires --repo, --title, and --prompt" 3
  fi

  init_schema

  local escaped_repo escaped_title escaped_prompt
  escaped_repo="$(sql_escape "$REPO")"
  escaped_title="$(sql_escape "$TITLE")"
  escaped_prompt="$(sql_escape "$PROMPT")"

  local conversation_id
  conversation_id="conv-$(date +%s)-$$-$(printf '%s' "$REPO:$TITLE" | md5sum | cut -d' ' -f1 | cut -c1-8)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local issue_body
  issue_body="$(cat <<EOF
# ${TITLE}

## Task
${PROMPT}

---
*Created by Manul conversation orchestrator*
EOF
)"

  local issue_response issue_number issue_url
  issue_response=""
  issue_number=""
  issue_url=""

  if ! command -v gh >/dev/null 2>&1; then
    error_exit "GitHub CLI (gh) is required to create the conversation issue" 1
  fi

  if ! issue_response="$(gh issue create \
      --repo "$REPO" \
      --title "$TITLE" \
      --body "$issue_body" \
      --json url,number 2>/dev/null)"; then
    error_exit "Failed to create GitHub issue for conversation" 1
  fi

  if ! issue_number="$(printf '%s' "$issue_response" | jq -r '.number // empty' 2>/dev/null)" || [ -z "$issue_number" ] || ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [ "$issue_number" -le 0 ]; then
    error_exit "GitHub issue creation returned an invalid issue number" 1
  fi

  if ! issue_url="$(printf '%s' "$issue_response" | jq -r '.url // empty' 2>/dev/null)" || [ -z "$issue_url" ]; then
    error_exit "GitHub issue creation returned an invalid issue URL" 1
  fi

  if ! sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt)
    VALUES('$conversation_id', '$escaped_repo', $issue_number, '$(sql_escape "$issue_url")', 'OPEN', '$now', '$now');"; then
    error_exit "Failed to persist conversation after GitHub issue creation" 1
  fi

  local task_id
  task_id="task-${conversation_id}-init-$(date +%s)"

  local lease_expires
  lease_expires="$(date -u -d "now + 900 seconds" +%Y-%m-%dT%H:%M:%SZ)"

  if ! sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, agent, prompt, status, createdAt, heartbeatAt, leaseExpiresAt, conversationId, parentTaskId, action)
    VALUES('$task_id', '$escaped_repo', $issue_number, '$(sql_escape "$issue_url")', 'orchestrator', '${AGENT:-coder}', '$escaped_prompt', 'queued', '$now', NULL, '$lease_expires', '$conversation_id', NULL, 'IMPLEMENT');"; then
    error_exit "Failed to persist initial conversation task" 1
  fi

  if ! sqlite3 "$DB" "UPDATE conversations SET activeTaskId='$task_id', updatedAt='$now' WHERE conversationId='$conversation_id';"; then
    error_exit "Failed to persist active conversation task" 1
  fi

  local result
  result="{\"conversationId\": \"$conversation_id\", \"issueNumber\": $issue_number, \"issueUrl\": \"${issue_url//\"/\\\"}\", \"status\": \"OPEN\", \"activeTaskId\": \"$task_id\", \"action\": \"create\"}"

  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Conversation created:"
    echo "  conversationId: $conversation_id"
    echo "  issueNumber: $issue_number"
    echo "  issueUrl: $issue_url"
    echo "  activeTaskId: $task_id"
  fi
}

cmd_submit() {
  if [ -z "$CONVERSATION_ID" ] || [ -z "$PROMPT" ]; then
    error_exit "submit requires --conversation-id and --prompt" 3
  fi

  init_schema

  local conv_exists
  conv_exists="$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  if [ "$conv_exists" = "0" ]; then
    error_exit "Conversation not found: $CONVERSATION_ID" 2
  fi

  local conv_repo conv_issue_num conv_status
  conv_repo="$(sqlite3 "$DB" "SELECT repository FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  conv_issue_num="$(sqlite3 "$DB" "SELECT issueNumber FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  conv_status="$(sqlite3 "$DB" "SELECT status FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"

  local action="${ACTION_TYPE:-IMPLEMENT}"
  case "$action" in
    IMPLEMENT|REVIEW_FIX|VERIFY|INVESTIGATE|FINALIZE) ;;
    *) error_exit "Invalid action: $action. Must be one of: IMPLEMENT, REVIEW_FIX, VERIFY, INVESTIGATE, FINALIZE" 3 ;;
  esac

  local running_count
  running_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' AND status='running';" 2>/dev/null)"

  if [ "${running_count:-0}" -gt 0 ] && [ "$action" = "REVIEW_FIX" ] && [ -n "$PR_NUMBER" ]; then
    :
  elif [ "${running_count:-0}" -gt 0 ] && [ "$conv_status" != "REVIEW" ] && [ "$conv_status" != "FIXING" ]; then
    error_exit "Conversation has running tasks. Wait for completion before submitting." 3
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local task_id
  task_id="task-${CONVERSATION_ID}-$(date +%s)-$$"
  local context="action=${action};conversationId=${CONVERSATION_ID}"
  [ -n "$PARENT_TASK_ID" ] && context="${context};parentTaskId=${PARENT_TASK_ID}"
  [ -n "$PR_NUMBER" ] && context="${context};prNumber=${PR_NUMBER}"

  local escaped_prompt escaped_context
  escaped_prompt="$(sql_escape "$PROMPT")"
  escaped_context="$(sql_escape "$context")"

  if ! sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, agent, prompt, context, status, createdAt, heartbeatAt, leaseExpiresAt, conversationId, parentTaskId, action, prNumber)
    VALUES('$task_id', '$(sql_escape "$conv_repo")', $conv_issue_num, 'https://github.com/${conv_repo}/issues/${conv_issue_num}', 'orchestrator', '${AGENT:-coder}', '$escaped_prompt', '$escaped_context', 'queued', '$now', NULL, '$(date -u -d "now + 900 seconds" +%Y-%m-%dT%H:%M:%SZ)', '$CONVERSATION_ID', '$(sql_escape "${PARENT_TASK_ID:-}")', '$action', ${PR_NUMBER:-NULL});"; then
    error_exit "Failed to persist task" 1
  fi

  case "$action" in
    REVIEW_FIX)
      sqlite3 "$DB" "UPDATE conversations SET status='FIXING', activeTaskId='$task_id', activePrNumber='${PR_NUMBER:-}', updatedAt='$now' WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" ;;
    IMPLEMENT)
      sqlite3 "$DB" "UPDATE conversations SET status='WORKING', activeTaskId='$task_id', updatedAt='$now' WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" ;;
    VERIFY|INVESTIGATE)
      sqlite3 "$DB" "UPDATE conversations SET activeTaskId='$task_id', updatedAt='$now' WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" ;;
    FINALIZE)
      sqlite3 "$DB" "UPDATE conversations SET status='WORKING', activeTaskId='$task_id', updatedAt='$now' WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" ;;
  esac

  local result
  result="{\"taskId\": \"$task_id\", \"conversationId\": \"$CONVERSATION_ID\", \"status\": \"queued\", \"action\": \"$action\", \"repo\": \"$conv_repo\", \"issue\": $conv_issue_num}"
  if [ "$JSON_OUTPUT" = true ]; then echo "$result" | jq .; else echo "Task submitted:"; echo "  taskId: $task_id"; echo "  conversationId: $CONVERSATION_ID"; echo "  action: $action"; echo "  status: queued"; fi
}

cmd_status() {
  if [ -z "$CONVERSATION_ID" ]; then error_exit "status requires --conversation-id" 3; fi
  init_schema
  local conv_row
  conv_row="$(sqlite3 "$DB" "SELECT conversationId, repository, issueNumber, issueUrl, status, activeTaskId, activePrNumber, createdAt, updatedAt FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  if [ -z "$conv_row" ]; then error_exit "Conversation not found: $CONVERSATION_ID" 2; fi
  IFS='|' read -r conv_id repo issue_num issue_url status active_task active_pr created_at updated_at <<< "$conv_row"
  local tasks_json
  tasks_json="$(sqlite3 -json "$DB" "SELECT commentId as taskId, prompt, status, action, parentTaskId, prNumber, prUrl, createdAt, processedAt FROM processed_comments WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' ORDER BY createdAt ASC;" 2>/dev/null || echo "[]")"
  local latest_task_result="null"
  local latest_task_id
  latest_task_id="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' AND status='completed' ORDER BY processedAt DESC LIMIT 1;" 2>/dev/null)"
  if [ -n "$latest_task_id" ]; then
    local result_file="$MANUL_DIR/results/${latest_task_id}.json"
    if [ -f "$result_file" ]; then latest_task_result="$(cat "$result_file" | jq -c '. // empty' 2>/dev/null || echo "null")"; fi
  fi
  local result
  result=$(jq -n --arg conversationId "$conv_id" --arg repo "$repo" --argjson issueNumber "${issue_num:-0}" --arg issueUrl "$issue_url" --arg status "$status" --arg activeTaskId "${active_task:-}" --argjson activePrNumber "${active_pr:-null}" --arg createdAt "$created_at" --arg updatedAt "$updated_at" --argjson tasks "$tasks_json" --argjson latestResult "$latest_task_result" '{conversationId:$conversationId,repository:$repo,issueNumber:$issueNumber,issueUrl:$issueUrl,status:$status,activeTaskId:$activeTaskId,activePrNumber:$activePrNumber,createdAt:$createdAt,updatedAt:$updatedAt,tasks:$tasks,latestResult:$latestResult}')
  if [ "$JSON_OUTPUT" = true ]; then echo "$result" | jq .; else echo "Conversation: $conv_id"; echo "  Repository: $repo"; echo "  Issue: #$issue_num ($issue_url)"; echo "  Status: $status"; echo "  Active Task: ${active_task:-none}"; echo "  Active PR: ${active_pr:-none}"; echo "  Created: $created_at"; echo "  Updated: $updated_at"; echo ""; echo "Tasks:"; echo "$tasks_json" | jq -r '.[] | "  \(.taskId) [\(.status)] \(.action): \(.prompt[0:60])..."' 2>/dev/null || echo "  (no tasks)"; fi
}

cmd_result() {
  if [ -z "$TASK_ID" ]; then error_exit "result requires --task-id" 3; fi
  init_schema
  local task_row
  task_row="$(sqlite3 "$DB" "SELECT commentId, status, action, conversationId, prNumber, prUrl, repository, issueNumber, processedAt FROM processed_comments WHERE commentId='$(sql_escape "$TASK_ID")';" 2>/dev/null)"
  if [ -z "$task_row" ]; then error_exit "Task not found: $TASK_ID" 2; fi
  IFS='|' read -r task_id status action conv_id pr_num pr_url repo issue_num processed_at <<< "$task_row"
  local result_file="$MANUL_DIR/results/${TASK_ID}.json" final_result="{}"
  [ -f "$result_file" ] && final_result="$(cat "$result_file" 2>/dev/null || echo "{}")"
  local next_action="none"
  if [ -n "$conv_id" ]; then
    local conv_status
    conv_status="$(sqlite3 "$DB" "SELECT status FROM conversations WHERE conversationId='$(sql_escape "$conv_id")';" 2>/dev/null)")
    case "$conv_status" in WORKING) next_action="wait_for_completion";; REVIEW) next_action="request_review";; FIXING) next_action="submit_review_fix";; COMPLETED) next_action="none";; *) next_action="check_status";; esac
  fi
  local result
  result=$(cat <<EOF
{
  "taskId": $(printf '%s' "$task_id" | jq -Rs .),
  "status": $(printf '%s' "$status" | jq -Rs .),
  "action": $(printf '%s' "$action" | jq -Rs .),
  "conversationId": $(printf '%s' "${conv_id:-}" | jq -Rs .),
  "prNumber": ${pr_num:-null},
  "prUrl": $(printf '%s' "$pr_url" | jq -Rs .),
  "repository": $(printf '%s' "$repo" | jq -Rs .),
  "issueNumber": ${issue_num:-0},
  "processedAt": $(printf '%s' "${processed_at:-}" | jq -Rs .),
  "result": $final_result,
  "nextAction": $(printf '%s' "$next_action" | jq -Rs .)
}
EOF
)
  if [ "$JSON_OUTPUT" = true ]; then echo "$result" | jq .; else echo "Task Result: $task_id"; echo "  Status: $status"; echo "  Action: $action"; echo "  Conversation: $conv_id"; echo "  PR: ${pr_num:-none} (${pr_url:-none})"; echo "  Processed: ${processed_at:-not yet}"; [ -n "$final_result" ] && [ "$final_result" != "null" ] && { echo ""; echo "Result:"; echo "$final_result" | jq . 2>/dev/null || echo "$final_result"; }; fi
}

cmd_close() {
  if [ -z "$CONVERSATION_ID" ]; then error_exit "close requires --conversation-id" 3; fi
  init_schema
  local conv_exists
  conv_exists="$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  if [ "$conv_exists" = "0" ]; then error_exit "Conversation not found: $CONVERSATION_ID" 2; fi
  local incomplete
  incomplete="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' AND status IN ('queued', 'running');" 2>/dev/null)"
  if [ "${incomplete:-0}" -gt 0 ]; then error_exit "Cannot close conversation with incomplete tasks" 3; fi
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "UPDATE conversations SET status='COMPLETED', updatedAt='$now' WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';"
  local result
  result="{\"conversationId\": \"$CONVERSATION_ID\", \"status\": \"COMPLETED\", \"closedAt\": \"$now\"}"
  if [ "$JSON_OUTPUT" = true ]; then echo "$result" | jq .; else echo "Conversation $CONVERSATION_ID marked as COMPLETED"; fi
}

case "${ACTION:-}" in
  create) cmd_create ;;
  submit) cmd_submit ;;
  status) cmd_status ;;
  result) cmd_result ;;
  close) cmd_close ;;
  "") echo "Usage: manul-conversation <command> [options]" >&2; exit 3 ;;
  *) error_exit "Unknown command: $ACTION" 3 ;;
esac
