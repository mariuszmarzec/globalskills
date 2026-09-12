#!/bin/bash
# manul-result-feedback.sh - Result feedback handler for Manul GitHub control protocol
#
# This script handles posting structured results back to GitHub after task completion.
# It creates machine-readable event markers and human-readable summary comments.
#
# Result Events Posted:
#   TASK_DONE    - Task completed successfully
#   TASK_FAILED  - Task failed after all attempts
#   TASK_STARTED - Task execution began
#
# Comment Format:
#   <!-- manul:event {"type":"TASK_DONE","timestamp":"...","data":{...}} -->
#   Human-readable summary
#   ---
#   — manul 🐈
#
# Usage:
#   manul-result-feedback.sh post-done --repo REPO --issue NUMBER --comment-id ID --task-id ID --summary SUMMARY --pr-number N
#   manul-result-feedback.sh post-failed --repo REPO --issue NUMBER --comment-id ID --task-id ID --error ERROR
#   manul-result-feedback.sh post-started --repo REPO --issue NUMBER --comment-id ID --task-id ID
#   manul-result-feedback.sh verify-marker --repo REPO --issue NUMBER --comment-id ID --expected-task-id ID --expected-attempt N

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
ISSUE_NUMBER=""
COMMENT_ID=""
TASK_ID=""
SUMMARY=""
ERROR_MSG=""
PR_NUMBER=""
EXPECTED_ATTEMPT=""
SIGNATURE="— manul 🐈"

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --issue) ISSUE_NUMBER="$2"; shift 2 ;;
    --comment-id) COMMENT_ID="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --error) ERROR_MSG="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --expected-attempt) EXPECTED_ATTEMPT="$2"; shift 2 ;;
    --signature) SIGNATURE="$2"; shift 2 ;;
    post-done|post-failed|post-started|verify-marker) ACTION="$1"; shift ;;
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

# Get task attempt number from database
get_task_attempt() {
  local task_id="$1"

  if [ ! -f "$DB" ]; then
    echo "1"
    return
  fi

  local attempt
  attempt="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$(sql_escape "$task_id")' LIMIT 1;" 2>/dev/null || echo "1")"

  echo "${attempt:-1}"
}

# Get conversation ID for a task
get_task_conversation() {
  local task_id="$1"

  if [ ! -f "$DB" ]; then
    echo ""
    return
  fi

  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$(sql_escape "$task_id")' LIMIT 1;" 2>/dev/null || echo "")"

  echo "$conv_id"
}

# Build event marker HTML comment
build_event_marker() {
  local event_type="$1"
  local data="$2"

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local event_json
  event_json=$(jq -n \
    --arg type "$event_type" \
    --arg timestamp "$timestamp" \
    --argjson data "$(echo "$data" | jq '.' 2>/dev/null || echo '{}')" \
    '{
      type: $type,
      timestamp: $timestamp,
      data: $data
    }')

  echo "<!-- manul:event $(echo "$event_json" | jq -c .) -->"
}

# Post a comment to GitHub
post_comment() {
  local repo="$1"
  local issue="$2"
  local body="$3"

  if [ -z "$repo" ] || [ -z "$issue" ] || [ -z "$body" ]; then
    return 1
  fi

  local signature="— manul 🐈"
  local signed_body
  if [[ "$body" == *"$signature" ]]; then
    signed_body="$body"
  else
    signed_body="${body}"$'\n\n'"${signature}"
  fi

  gh issue comment "$issue" --repo "$repo" --body "$signed_body" 2>/dev/null
}

# Post TASK_DONE event
cmd_post_done() {
  if [ -z "$REPO" ] || [ -z "$TASK_ID" ]; then
    error_exit "post-done requires --repo and --task-id" 3
  fi

  local attempt
  attempt="$(get_task_attempt "$TASK_ID")"

  local conv_id
  conv_id="$(get_task_conversation "$TASK_ID")"

  # Build event data
  local event_data
  event_data=$(jq -n \
    --arg taskId "$TASK_ID" \
    --arg conversationId "${conv_id:-}" \
    --arg summary "${SUMMARY:0:500}" \
    --argjson prNumber "${PR_NUMBER:-null}" \
    --argjson attempt "$attempt" \
    '{
      taskId: $taskId,
      conversationId: $conversationId,
      summary: $summary,
      prNumber: $prNumber,
      attempt: $attempt
    }')

  # Build event marker
  local event_marker
  event_marker="$(build_event_marker "TASK_DONE" "$event_data")"

  # Build human-readable comment
  local comment_body=""
  comment_body+="${event_marker}"
  comment_body+=$'\n\n'
  comment_body+="✅ **Task Completed**"
  comment_body+=$'\n\n'
  comment_body+="**Task:** ${TASK_ID}"
  comment_body+=$'\n'
  if [ -n "${conv_id:-}" ]; then
    comment_body+="**Conversation:** ${conv_id}"
    comment_body+=$'\n'
  fi
  if [ -n "${PR_NUMBER:-}" ]; then
    comment_body+="**PR:** #${PR_NUMBER}"
    comment_body+=$'\n'
  fi
  comment_body+="**Attempt:** ${attempt}"
  comment_body+=$'\n\n'
  if [ -n "${SUMMARY:-}" ]; then
    comment_body+="**Summary:**\n${SUMMARY}"
    comment_body+=$'\n\n'
  fi
  comment_body+="---"
  comment_body+=$'\n'
  comment_body+="${SIGNATURE}"

  local result
  result=$(jq -n \
    --arg taskId "$TASK_ID" \
    --arg conversationId "${conv_id:-}" \
    --arg summary "${SUMMARY:0:200}" \
    --argjson prNumber "${PR_NUMBER:-null}" \
    --argjson attempt "$attempt" \
    --arg marker "$event_marker" \
    '{
      taskId: $taskId,
      conversationId: $conversationId,
      status: "completed",
      attempt: $attempt,
      prNumber: $prNumber,
      eventMarker: $marker,
      hasSummary: ($summary != "")
    }')

  # Post the comment to GitHub
  post_comment "$REPO" "${ISSUE_NUMBER:-$PR_NUMBER}" "$comment_body" || true

  echo "$result" | jq .
}

# Post TASK_FAILED event
cmd_post_failed() {
  if [ -z "$REPO" ] || [ -z "$TASK_ID" ]; then
    error_exit "post-failed requires --repo and --task-id" 3
  fi

  local attempt
  attempt="$(get_task_attempt "$TASK_ID")"

  local conv_id
  conv_id="$(get_task_conversation "$TASK_ID")"

  # Build event data
  local event_data
  event_data=$(jq -n \
    --arg taskId "$TASK_ID" \
    --arg conversationId "${conv_id:-}" \
    --arg error "${ERROR_MSG:0:500}" \
    --argjson prNumber "${PR_NUMBER:-null}" \
    --argjson attempt "$attempt" \
    '{
      taskId: $taskId,
      conversationId: $conversationId,
      error: $error,
      prNumber: $prNumber,
      attempt: $attempt
    }')

  # Build event marker
  local event_marker
  event_marker="$(build_event_marker "TASK_FAILED" "$event_data")"

  # Build human-readable comment
  local comment_body=""
  comment_body+="${event_marker}"
  comment_body+=$'\n\n'
  comment_body+="❌ **Task Failed**"
  comment_body+=$'\n\n'
  comment_body+="**Task:** ${TASK_ID}"
  comment_body+=$'\n'
  if [ -n "${conv_id:-}" ]; then
    comment_body+="**Conversation:** ${conv_id}"
    comment_body+=$'\n'
  fi
  comment_body+="**Attempt:** ${attempt}/${attempt}"
  comment_body+=$'\n\n'
  if [ -n "${ERROR_MSG:-}" ]; then
    comment_body+="**Error:**\n\`\`\`\n${ERROR_MSG}\n\`\`\`"
    comment_body+=$'\n\n'
  fi
  comment_body+="---"
  comment_body+=$'\n'
  comment_body+="${SIGNATURE}"

  local result
  result=$(jq -n \
    --arg taskId "$TASK_ID" \
    --arg conversationId "${conv_id:-}" \
    --arg error "${ERROR_MSG:0:200}" \
    --argjson prNumber "${PR_NUMBER:-null}" \
    --argjson attempt "$attempt" \
    --arg marker "$event_marker" \
    '{
      taskId: $taskId,
      conversationId: $conversationId,
      status: "failed",
      attempt: $attempt,
      prNumber: $prNumber,
      eventMarker: $marker,
      hasError: ($error != "")
    }')

  # Post the comment to GitHub
  post_comment "$REPO" "${ISSUE_NUMBER:-$PR_NUMBER}" "$comment_body" || true

  echo "$result" | jq .
}

# Post TASK_STARTED event
cmd_post_started() {
  if [ -z "$REPO" ] || [ -z "$TASK_ID" ]; then
    error_exit "post-started requires --repo and --task-id" 3
  fi

  local attempt
  attempt="$(get_task_attempt "$TASK_ID")"

  local conv_id
  conv_id="$(get_task_conversation "$TASK_ID")"

  # Build event data
  local event_data
  event_data=$(jq -n \
    --arg taskId "$TASK_ID" \
    --arg conversationId "${conv_id:-}" \
    --argjson attempt "$attempt" \
    '{
      taskId: $taskId,
      conversationId: $conversationId,
      attempt: $attempt
    }')

  # Build event marker
  local event_marker
  event_marker="$(build_event_marker "TASK_STARTED" "$event_data")"

  # Build human-readable comment
  local comment_body=""
  comment_body+="${event_marker}"
  comment_body+=$'\n\n'
  comment_body+="🔄 **Task Started**"
  comment_body+=$'\n\n'
  comment_body+="**Task:** ${TASK_ID}"
  comment_body+=$'\n'
  if [ -n "${conv_id:-}" ]; then
    comment_body+="**Conversation:** ${conv_id}"
    comment_body+=$'\n'
  fi
  comment_body+="**Attempt:** ${attempt}"
  comment_body+=$'\n\n'
  comment_body+="---"
  comment_body+=$'\n'
  comment_body+="${SIGNATURE}"

  local result
  result=$(jq -n \
    --arg taskId "$TASK_ID" \
    --arg conversationId "${conv_id:-}" \
    --argjson attempt "$attempt" \
    --arg marker "$event_marker" \
    '{
      taskId: $taskId,
      conversationId: $conversationId,
      status: "started",
      attempt: $attempt,
      eventMarker: $marker
    }')

  # Post the comment to GitHub
  post_comment "$REPO" "${ISSUE_NUMBER:-$PR_NUMBER}" "$comment_body" || true

  echo "$result" | jq .
}

# Verify that a comment contains the expected event marker
cmd_verify_marker() {
  if [ -z "$REPO" ] || [ -z "$COMMENT_ID" ] || [ -z "$TASK_ID" ]; then
    error_exit "verify-marker requires --repo, --comment-id, and --task-id" 3
  fi

  local found=false
  local match_attempt=""

  # Query GitHub for the comment
  local comment_body=""
  if command -v gh >/dev/null 2>&1; then
    comment_body="$(gh api "repos/${REPO}/issues/comments/${COMMENT_ID}" --jq '.body // ""' 2>/dev/null || echo "")"
  fi

  # Extract event markers
  local event_marker
  event_marker="$(grep -oE '<!-- manul:event [^>]+ -->' <<< "$comment_body" 2>/dev/null | head -1 || echo "")"

  if [ -n "$event_marker" ]; then
    found=true
    # Extract attempt from marker if present
    match_attempt="$(echo "$event_marker" | grep -oP '(?<="attempt":)[0-9]+' || echo "")"
  fi

  # Check if task ID matches
  local task_match=false
  if echo "$event_marker" | grep -q "$TASK_ID"; then
    task_match=true
  fi

  local result
  result=$(jq -n \
    --arg commentId "$COMMENT_ID" \
    --arg taskId "$TASK_ID" \
    --argjson found "$found" \
    --argjson taskMatch "$task_match" \
    --arg expectedAttempt "${EXPECTED_ATTEMPT:-}" \
    --arg actualAttempt "${match_attempt:-}" \
    --arg marker "$event_marker" \
    '{
      commentId: $commentId,
      taskId: $taskId,
      hasMarker: $found,
      taskMatch: $taskMatch,
      expectedAttempt: $expectedAttempt,
      actualAttempt: $actualAttempt,
      marker: $marker,
      valid: ($found and $taskMatch)
    }')

  echo "$result" | jq .
}

# Main dispatch
case "${ACTION:-}" in
  post-done) cmd_post_done ;;
  post-failed) cmd_post_failed ;;
  post-started) cmd_post_started ;;
  verify-marker) cmd_verify_marker ;;
  "")
    echo "Usage: manul-result-feedback.sh <command> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  post-done        Post TASK_DONE event and comment" >&2
    echo "  post-failed      Post TASK_FAILED event and comment" >&2
    echo "  post-started     Post TASK_STARTED event and comment" >&2
    echo "  verify-marker    Verify event marker in a comment" >&2
    exit 3
    ;;
  *)
    error_exit "Unknown command: $ACTION" 3
    ;;
esac
