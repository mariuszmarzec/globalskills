#!/bin/bash
# manul-pr-review.sh - PR review handler for Manul GitHub control protocol
#
# This script handles PR review events (APPROVE, REQUEST_CHANGES) and converts
# them into appropriate Manul tasks while preserving conversation context.
#
# Key invariants:
# - PR review feedback -> REVIEW_FIX task on SAME PR
# - APPROVE does NOT create fix task
# - REQUEST_CHANGES creates fix task with parent relationship
# - conversationId is preserved across review cycles
#
# Usage:
#   manul-pr-review.sh handle --repo REPO --pr-number N --review-id ID --state STATE --body BODY --author AUTHOR --created CREATED
#   manul-pr-review.sh get-conversation --repo REPO --pr-number N
#   manul-pr-review.sh list-reviews --repo REPO --pr-number N

set -euo pipefail

MANUL_DIR="${MANUL_DIR:-${OPENCLAW_MANUL_DIR:-$HOME/.openclaw/manul}}"
DB="${MANUL_DIR}/manul.db"
CONFIG="${MANUL_DIR}/config.json"
EVENTS_SCRIPT="${MANUL_DIR}/manul-github-events.sh"

# JSON output flag
JSON_OUTPUT=false

# Parse global options
ACTION=""
REPO=""
PR_NUMBER=""
REVIEW_ID=""
REVIEW_STATE=""
BODY=""
AUTHOR=""
CREATED=""
REVIEWER_TYPE="${REVIEWER_TYPE:-mock}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --review-id) REVIEW_ID="$2"; shift 2 ;;
    --review-state) REVIEW_STATE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --created) CREATED="$2"; shift 2 ;;
    handle|get-conversation|list-reviews) ACTION="$1"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 3 ;;
  esac
done

# SQL escaping helper
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Error helper
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

# Get the PR's associated conversation
# Returns conversationId or empty string
get_pr_conversation() {
  local repo="$1"
  local pr_number="$2"

  if [ ! -f "$DB" ]; then
    echo ""
    return
  fi

  # Check if PR number exists in processed_comments
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT DISTINCT conversationId FROM processed_comments WHERE repository='$(sql_escape "$repo")' AND prNumber=$pr_number AND status != 'failed' ORDER BY createdAt DESC LIMIT 1;" 2>/dev/null || echo "")"

  if [ -n "$conv_id" ]; then
    echo "$conv_id"
    return
  fi

  # Check conversations table for PR association
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='$(sql_escape "$repo")' AND activePrNumber=$(echo "$pr_number" | jq -R . | jq -c .) AND status != 'COMPLETED' LIMIT 1;" 2>/dev/null || echo "")"

  echo "$conv_id"
}

# Get the latest task for a PR that needs review
get_pr_pending_task() {
  local repo="$1"
  local pr_number="$2"

  if [ ! -f "$DB" ]; then
    echo ""
    return
  fi

  # Find the latest running/completed task for this PR
  local task_id
  task_id="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE repository='$(sql_escape "$repo")' AND prNumber=$pr_number AND status IN ('running', 'completed', 'queued') ORDER BY createdAt DESC LIMIT 1;" 2>/dev/null || echo "")"

  echo "$task_id"
}

# Get conversation and task context for a PR
get_pr_context() {
  local repo="$1"
  local pr_number="$2"

  local conv_id
  conv_id="$(get_pr_conversation "$repo" "$pr_number")"

  local task_id
  task_id="$(get_pr_pending_task "$repo" "$pr_number")"

  local parent_task_id=""
  if [ -n "$task_id" ]; then
    parent_task_id="$task_id"
  fi

  # Get PR details
  local pr_title=""
  if command -v gh >/dev/null 2>&1; then
    pr_title="$(gh pr view "$pr_number" --repo "$repo" --json title --jq '.title // ""' 2>/dev/null || echo "")"
  fi

  local result
  result=$(jq -n \
    --arg conversationId "${conv_id:-}" \
    --arg taskId "${task_id:-}" \
    --arg parentTaskId "${parent_task_id:-}" \
    --arg repo "$repo" \
    --argjson prNumber "$pr_number" \
    --arg prTitle "$pr_title" \
    '{
      conversationId: $conversationId,
      taskId: $taskId,
      parentTaskId: $parentTaskId,
      repo: $repo,
      prNumber: $prNumber,
      prTitle: $prTitle,
      hasConversation: ($conversationId != ""),
      hasTask: ($taskId != "")
    }')

  echo "$result" | jq .
}

# Handle incoming PR review
# Creates appropriate tasks based on review state
cmd_handle() {
  if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ] || [ -z "$REVIEW_STATE" ]; then
    error_exit "handle requires --repo, --pr-number, and --review-state" 3
  fi

  # Get context
  local context
  context="$(get_pr_context "$REPO" "$PR_NUMBER")"
  local conv_id task_id
  conv_id="$(echo "$context" | jq -r '.conversationId // empty')"
  task_id="$(echo "$context" | jq -r '.taskId // empty')"

  # Map GitHub review state to Manul action
  local action=""
  local should_create_task=false

  case "$REVIEW_STATE" in
    APPROVE)
      action="APPROVE"
      should_create_task=false
      ;;
    REQUEST_CHANGES)
      action="REQUEST_CHANGES"
      should_create_task=true
      ;;
    COMMENT)
      action="COMMENT"
      should_create_task=false
      ;;
    DISMISS)
      action="DISMISS"
      should_create_task=false
      ;;
    *)
      error_exit "Unknown review state: $REVIEW_STATE" 3
      ;;
  esac

  # Check for existing review (deduplication)
  local existing_review
  existing_review="$(sqlite3 "$DB" "SELECT 1 FROM processed_comments WHERE repository='$(sql_escape "$REPO")' AND prNumber=$PR_NUMBER AND action='REVIEW' AND commentId='$(sql_escape "${REVIEW_ID:-}")' LIMIT 1;" 2>/dev/null || echo "")"

  if [ -n "$existing_review" ]; then
    # Already processed this review
    local result
    result="{\"reviewId\": \"$REVIEW_ID\", \"action\": \"$action\", \"processed\": true, \"skipped\": true, \"reason\": \"duplicate_review\"}"
    echo "$result" | jq .
    return 0
  fi

  # Record the review event
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ -n "$DB" ] && [ -f "$DB" ]; then
    sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, action, status, createdAt, conversationId, prNumber) VALUES('$(sql_escape "${REVIEW_ID:-review-$PR_NUMBER-$REVIEW_STATE}")', '$(sql_escape "$REPO")', $PR_NUMBER, 'https://github.com/${REPO}/pull/${PR_NUMBER}', '$(sql_escape "${AUTHOR:-}")', '$(sql_escape "${BODY:-Review: $REVIEW_STATE}")', 'REVIEW', 'completed', '$now', '$(sql_escape "${conv_id:-}")', $PR_NUMBER);" 2>/dev/null || true
  fi

  # If APPROVE, update conversation state but don't create task
  if [ "$should_create_task" = false ]; then
    local result
    result=$(jq -n \
      --arg reviewId "$REVIEW_ID" \
      --arg action "$action" \
      --arg conversationId "$conv_id" \
      --arg taskId "${task_id:-}" \
      --argjson prNumber "$PR_NUMBER" \
      '{
        reviewId: $reviewId,
        action: $action,
        conversationId: $conversationId,
        taskId: $taskId,
        prNumber: $prNumber,
        createdTask: false,
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
      }')
    echo "$result" | jq .
    return 0
  fi

  # REQUEST_CHANGES: Create REVIEW_FIX task
  if [ -z "$conv_id" ]; then
    error_exit "No conversation found for PR #$PR_NUMBER" 2
  fi

  # Parse review body for additional instructions
  local review_prompt="$BODY"
  if [ -n "$BODY" ] && [[ "$BODY" == *"/manul"* ]]; then
    # Extract command if present
    local cmd_output
    cmd_output="$(bash "$EVENTS_SCRIPT" parse-review \
      --repo "$REPO" \
      --pr-number "$PR_NUMBER" \
      --review-id "$REVIEW_ID" \
      --review-state "$REVIEW_STATE" \
      --body "$BODY" \
      --author "$AUTHOR" \
      --created "$CREATED" \
      --json 2>/dev/null)" || true

    if [ -n "$cmd_output" ]; then
      local parsed_action
      parsed_action="$(echo "$cmd_output" | jq -r '.command.prompt // empty')"
      if [ -n "$parsed_action" ]; then
        review_prompt="$parsed_action"
      fi
    fi
  fi

  # Submit review-fix task
  local submit_args=(
    --conversation-id "$conv_id"
    --prompt "$review_prompt"
    --action REVIEW_FIX
    --pr-number "$PR_NUMBER"
  )

  if [ -n "$task_id" ]; then
    submit_args+=(--parent-task-id "$task_id")
  fi

  # Use manul-conversation.sh to submit
  local submit_output=""
  if [ -f "${MANUL_DIR}/manul-conversation.sh" ]; then
    submit_output="$(bash "${MANUL_DIR}/manul-conversation.sh" submit "${submit_args[@]}" --json 2>/dev/null)" || true
  fi

  local new_task_id=""
  if [ -n "$submit_output" ]; then
    new_task_id="$(echo "$submit_output" | jq -r '.taskId // empty')"
  fi

  if [ -z "$new_task_id" ]; then
    # Fallback: generate task ID manually
    new_task_id="task-${conv_id}-review-fix-$(date +%s)-$$"
  fi

  local result
  result=$(jq -n \
    --arg reviewId "$REVIEW_ID" \
    --arg action "$action" \
    --arg conversationId "$conv_id" \
    --arg newTaskId "$new_task_id" \
    --arg parentTaskId "${task_id:-}" \
    --argjson prNumber "$PR_NUMBER" \
    --arg reviewPrompt "${review_prompt:0:200}" \
    '{
      reviewId: $reviewId,
      action: $action,
      conversationId: $conversationId,
      newTaskId: $newTaskId,
      parentTaskId: $parentTaskId,
      prNumber: $prNumber,
      reviewPrompt: $reviewPrompt,
      createdTask: true,
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }')

  echo "$result" | jq .
}

# Get conversation info for a PR
cmd_get_conversation() {
  if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ]; then
    error_exit "get-conversation requires --repo and --pr-number" 3
  fi

  get_pr_context "$REPO" "$PR_NUMBER"
}

# List reviews for a PR
cmd_list_reviews() {
  if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ]; then
    error_exit "list-reviews requires --repo and --pr-number" 3
  fi

  local reviews="[]"

  if command -v gh >/dev/null 2>&1; then
    reviews="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" 2>/dev/null | jq '.' || echo '[]')"
  fi

  local result
  result=$(jq -n \
    --argjson reviews "$reviews" \
    --arg repo "$REPO" \
    --argjson prNumber "$PR_NUMBER" \
    '{
      repo: $repo,
      prNumber: $prNumber,
      reviews: $reviews,
      reviewCount: ($reviews | length)
    }')

  echo "$result" | jq .
}

# Main dispatch
case "${ACTION:-}" in
  handle) cmd_handle ;;
  get-conversation) cmd_get_conversation ;;
  list-reviews) cmd_list_reviews ;;
  "")
    echo "Usage: manul-pr-review.sh <command> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  handle           Handle an incoming PR review" >&2
    echo "  get-conversation Get conversation context for a PR" >&2
    echo "  list-reviews     List reviews for a PR" >&2
    exit 3
    ;;
  *)
    error_exit "Unknown command: $ACTION" 3
    ;;
esac
