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
# - Crash-safe: exactly-one task creation even across crashes/restarts
#
# Usage:
#   manul-pr-review.sh handle --repo REPO --pr-number N --review-id ID --state STATE --body BODY --author AUTHOR --created CREATED
#   manul-pr-review.sh get-conversation --repo REPO --pr-number N
#   manul-pr-review.sh list-reviews --repo REPO --pr-number N
#
# Review state machine (stored in processed_comments):
#   pending     - review claimed, task not yet created
#   task_created - task created, taskId stored, awaiting completion
#   completed   - task completed successfully
#   failed      - task creation or execution failed
#
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
    --json) JSON_OUTPUT=true; shift 1 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --review-id) REVIEW_ID="$2"; shift 2 ;;
    --review-state) REVIEW_STATE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --created) CREATED="$2"; shift 2 ;;
    handle|get-conversation|list-reviews) ACTION="$1"; shift 1 ;;
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

# Ensure the processed_comments table has the taskId column for review-task association.
# Idempotent: safe to call multiple times, works on fresh and existing DBs.
init_schema() {
  mkdir -p "$(dirname "$DB")"

  # Create processed_comments table if not exists (mimics manul-conversation.sh schema)
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
    prUrl TEXT,
    resultSummary TEXT,
    resultJson TEXT,
    baseId TEXT
  );" 2>/dev/null || true

  # Migrate: add taskId column if missing (for review-task association)
  local has_task_id
  has_task_id="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" | grep -c '|taskId|')"
  if [ "$has_task_id" -eq 0 ]; then
    sqlite3 "$DB" "BEGIN IMMEDIATE; ALTER TABLE processed_comments ADD COLUMN taskId TEXT; COMMIT;" || {
      echo "ERROR: failed to add taskId column to processed_comments" >&2
      return 1
    }
  fi
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
  conv_id="$(sqlite3 "$DB" "SELECT DISTINCT conversationId FROM processed_comments WHERE repository='$(sql_escape "$repo")' AND prNumber=$pr_number AND status != 'failed' AND action != 'REVIEW' ORDER BY createdAt DESC LIMIT 1;" 2>/dev/null || echo "")"

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

  # Find the latest running/completed task for this PR (exclude REVIEW actions only)
  local task_id
  task_id="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE repository='$(sql_escape "$repo")' AND prNumber=$pr_number AND status IN ('running', 'completed') AND action NOT IN ('REVIEW') ORDER BY createdAt DESC LIMIT 1;" 2>/dev/null || echo "")"

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
# Implements crash-safe idempotent state machine:
#   pending -> task_created -> completed
cmd_handle() {
  if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ] || [ -z "$REVIEW_STATE" ]; then
    error_exit "handle requires --repo, --pr-number, and --review-state" 3
  fi

  # Initialize schema (migrate if needed)
  init_schema || error_exit "Failed to initialize schema" 1

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

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local review_id="${REVIEW_ID:-review-$PR_NUMBER-$REVIEW_STATE}"
  local review_comment_id="review:$review_id"

  # ========================================================================
  # Phase 1: Check existing review record and determine recovery action
  # ========================================================================
  local review_status=""
  local existing_task_id=""

  if [ -n "$DB" ] && [ -f "$DB" ]; then
    # Atomically check status and extract any existing taskId
    local status_row
    status_row="$(sqlite3 "$DB" "BEGIN IMMEDIATE; SELECT status, taskId FROM processed_comments WHERE commentId='$review_comment_id' AND action='REVIEW' LIMIT 1; COMMIT;" 2>/dev/null || echo "")"

    if [ -n "$status_row" ]; then
      review_status="$(echo "$status_row" | cut -d'|' -f1)"
      existing_task_id="$(echo "$status_row" | cut -d'|' -f2)"
    fi
  fi

  # ========================================================================
  # Phase 2: Handle non-REQUEST_CHANGES reviews (APPROVE/DISMISS/COMMENT)
  # ========================================================================
  if [ "$should_create_task" = false ]; then
    # For APPROVE/DISMISS/COMMENT: record as completed (no task creation)
    if [ -n "$DB" ] && [ -f "$DB" ]; then
      sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, action, status, createdAt, conversationId, prNumber) VALUES('$(sql_escape "$review_comment_id")', '$(sql_escape "$REPO")', $PR_NUMBER, 'https://github.com/${REPO}/pull/${PR_NUMBER}', '$(sql_escape "${AUTHOR:-}")', '$(sql_escape "${BODY:-Review: $REVIEW_STATE}")', 'REVIEW', 'completed', '$now', '$(sql_escape "${conv_id:-}")', $PR_NUMBER);" 2>/dev/null || {
        echo "ERROR: failed to record review $review_id" >&2
        return 1
      }
    fi

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

  # ========================================================================
  # Phase 3: REQUEST_CHANGES - crash-safe task creation with state machine
  # ========================================================================

  # Parse review body for additional instructions
  local review_prompt="$BODY"
  if [ -n "$BODY" ] && [[ "$BODY" == *"/manul"* ]]; then
    local cmd_output
    cmd_output="$(bash "$EVENTS_SCRIPT" parse-review \
      --repo "$REPO" \
      --pr-number "$PR_NUMBER" \
      --review-id "$REVIEW_ID" \
      --review-state "$REVIEW_STATE" \
      --body "$BODY" \
      --author "$AUTHOR" \
      --created "$CREATED" \
      --json 2>/dev/null)" || cmd_output=""

    if [ -n "$cmd_output" ]; then
      local parsed_action
      parsed_action="$(echo "$cmd_output" | jq -r '.command.prompt // empty')"
      if [ -n "$parsed_action" ]; then
        review_prompt="$parsed_action"
      fi
    fi
  fi

  # State machine: handle based on existing review status
  case "$review_status" in
    completed)
      # Already completed successfully - skip
      local result
      result=$(jq -n \
        --arg reviewId "$review_id" \
        --arg action "$action" \
        --arg conversationId "$conv_id" \
        --arg parentTaskId "${task_id:-}" \
        --argjson prNumber "$PR_NUMBER" \
        --arg reviewPrompt "${review_prompt:0:200}" \
        '{
          reviewId: $reviewId,
          action: $action,
          conversationId: $conversationId,
          newTaskId: null,
          parentTaskId: $parentTaskId,
          prNumber: $prNumber,
          reviewPrompt: $reviewPrompt,
          createdTask: false,
          duplicate: true,
          timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        }')
      echo "$result" | jq .
      return 0
      ;;

    task_created)
      # Task was created in a previous run - reuse it (crash recovery)
      if [ -n "$existing_task_id" ]; then
        echo "dispatch: review $review_id already has task $existing_task_id, reusing" >&2
        local result
        result=$(jq -n \
          --arg reviewId "$review_id" \
          --arg action "$action" \
          --arg conversationId "$conv_id" \
          --arg newTaskId "$existing_task_id" \
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
            reused: true,
            timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
          }')
        echo "$result" | jq .
        return 0
      else
        # Corrupted state: task_created but no taskId - treat as pending
        echo "dispatch: review $review_id has task_created without taskId, recovering" >&2
        review_status=""
        existing_task_id=""
      fi
      ;;

    pending)
      # Review claimed but task not yet created - check if taskId was stored
      if [ -n "$existing_task_id" ]; then
        # Should not happen (task_created should have taskId), but handle gracefully
        echo "dispatch: review $review_id has pending status with taskId $existing_task_id, updating to task_created" >&2
      if [ -n "$DB" ] && [ -f "$DB" ]; then
        sqlite3 "$DB" "UPDATE processed_comments SET status='task_created' WHERE commentId='$review_comment_id' AND status='pending';" || {
          echo "ERROR: failed to update review $review_id status to task_created" >&2
          return 1
        }
      fi
        local result
        result=$(jq -n \
          --arg reviewId "$review_id" \
          --arg action "$action" \
          --arg conversationId "$conv_id" \
          --arg newTaskId "$existing_task_id" \
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
            reused: true,
            timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
          }')
        echo "$result" | jq .
        return 0
      fi
      # No taskId yet - proceed to create task (fall through)
      ;;

    failed)
      # Previous attempt failed - clear and retry
      echo "dispatch: review $review_id previously failed, retrying" >&2
      if [ -n "$DB" ] && [ -f "$DB" ]; then
        sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='$review_comment_id' AND action='REVIEW';" 2>/dev/null || {
          echo "ERROR: failed to clear failed review $review_id" >&2
          return 1
        }
      fi
      review_status=""
      existing_task_id=""
      ;;

    "")
      # No existing record - proceed to create
      ;;

    *)
      # Unknown state - clear and retry
      echo "dispatch: review $review_id has unknown status '$review_status', clearing and retrying" >&2
      if [ -n "$DB" ] && [ -f "$DB" ]; then
        sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='$review_comment_id' AND action='REVIEW';" || {
          echo "ERROR: failed to clear unknown-state review $review_id" >&2
          return 1
        }
      fi
      review_status=""
      existing_task_id=""
      ;;
  esac

  # ========================================================================
  # Phase 4: Claim the review (only if no existing record)
  # ========================================================================
  if [ -n "$DB" ] && [ -f "$DB" ] && [ -z "$review_status" ]; then
    # No existing record - insert as pending
    local insert_result
    insert_result="$(sqlite3 "$DB" "BEGIN IMMEDIATE; INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, action, status, createdAt, conversationId, prNumber) VALUES('$review_comment_id', '$(sql_escape "$REPO")', $PR_NUMBER, 'https://github.com/${REPO}/pull/${PR_NUMBER}', '$(sql_escape "${AUTHOR:-}")', '$(sql_escape "${BODY:-Review: $REVIEW_STATE}")', 'REVIEW', 'pending', '$now', '$(sql_escape "$conv_id")', $PR_NUMBER); SELECT changes(); COMMIT;" 2>/dev/null)" || {
      echo "ERROR: failed to claim review $review_id" >&2
      return 1
    }
    local inserted="${insert_result%%$'
'*}"
    if [ "${inserted:-0}" -eq 0 ]; then
      # Race condition: another process inserted first, read its state
      echo "dispatch: duplicate review $review_id during claim (race), reading state" >&2
      local race_status race_task
      race_status="$(sqlite3 "$DB" "SELECT status, taskId FROM processed_comments WHERE commentId='$review_comment_id' AND action='REVIEW' LIMIT 1;" 2>/dev/null || echo "")"
      if [ -n "$race_status" ]; then
        local rs rt
        rs="$(echo "$race_status" | cut -d'|' -f1)"
        rt="$(echo "$race_status" | cut -d'|' -f2)"
        if [ "$rs" = "task_created" ] && [ -n "$rt" ]; then
          local result
          result=$(jq -n \
            --arg reviewId "$review_id" \
            --arg action "$action" \
            --arg conversationId "$conv_id" \
            --arg newTaskId "$rt" \
            --arg parentTaskId "${task_id:-}" \
            --argjson prNumber "$PR_NUMBER" \
            '{
              reviewId: $reviewId,
              action: $action,
              conversationId: $conversationId,
              newTaskId: $newTaskId,
              parentTaskId: $parentTaskId,
              prNumber: $prNumber,
              createdTask: true,
              reused: true,
              timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }')
          echo "$result" | jq .
          return 0
        fi
        # Race resulted in pending or other state - fall through
      fi
    fi
  fi

  # ========================================================================
  # Phase 5: Create REVIEW_FIX task via manul-conversation.sh
  # ========================================================================
  if [ -z "$conv_id" ]; then
    error_exit "No conversation found for PR #$PR_NUMBER" 2
  fi

  local submit_args=(
    --conversation-id "$conv_id"
    --prompt "$review_prompt"
    --action REVIEW_FIX
    --pr-number "$PR_NUMBER"
    --review-id "$REVIEW_ID"
  )

  if [ -n "$task_id" ]; then
    submit_args+=(--parent-task-id "$task_id")
  fi

  local submit_output=""
  if [ -f "${MANUL_DIR}/manul-conversation.sh" ]; then
    submit_output="$(bash "${MANUL_DIR}/manul-conversation.sh" submit "${submit_args[@]}" --json 2>/dev/null)" || {
      # Submit failed - update review to failed state
      if [ -n "$DB" ] && [ -f "$DB" ]; then
        sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending';" || {
          echo "ERROR: failed to mark review $review_id as failed (submit_failed)" >&2
          return 1
        }
      fi
      local fail_result
      fail_result=$(jq -n \
        --arg reviewId "$REVIEW_ID" \
        --arg action "$action" \
        --arg conversationId "$conv_id" \
        --arg parentTaskId "${task_id:-}" \
        --argjson prNumber "$PR_NUMBER" \
        '{
          reviewId: $reviewId,
          action: $action,
          conversationId: $conversationId,
          newTaskId: null,
          parentTaskId: $parentTaskId,
          prNumber: $prNumber,
          createdTask: false,
          error: "submit_failed",
          timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        }')
      echo "$fail_result" | jq .
      return 1
    }
  else
    # manul-conversation.sh not found - cannot create task
    if [ -n "$DB" ] && [ -f "$DB" ]; then
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending';" 2>/dev/null || true
    fi
    local fail_result
    fail_result=$(jq -n \
      --arg reviewId "$REVIEW_ID" \
      --arg action "$action" \
      --arg conversationId "$conv_id" \
      --arg parentTaskId "${task_id:-}" \
      --argjson prNumber "$PR_NUMBER" \
      '{
        reviewId: $reviewId,
        action: $action,
        conversationId: $conversationId,
        newTaskId: null,
        parentTaskId: $parentTaskId,
        prNumber: $prNumber,
        createdTask: false,
        error: "conversation_script_missing",
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
      }')
    echo "$fail_result" | jq .
    return 1
  fi

  # ========================================================================
  # Phase 6: Extract taskId and record atomically
  # ========================================================================
  local new_task_id=""
  local submit_success=false

  if [ -n "$submit_output" ]; then
    new_task_id="$(echo "$submit_output" | jq -r '.taskId // empty')"
    if [ -n "$new_task_id" ]; then
      submit_success=true
    fi
  fi

  if [ "$submit_success" = false ]; then
    # Submit returned no taskId - mark as failed
    if [ -n "$DB" ] && [ -f "$DB" ]; then
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending';" 2>/dev/null || true
    fi
    local fail_result
    fail_result=$(jq -n \
      --arg reviewId "$REVIEW_ID" \
      --arg action "$action" \
      --arg conversationId "$conv_id" \
      --arg parentTaskId "${task_id:-}" \
      --argjson prNumber "$PR_NUMBER" \
      '{
        reviewId: $reviewId,
        action: $action,
        conversationId: $conversationId,
        newTaskId: null,
        parentTaskId: $parentTaskId,
        prNumber: $prNumber,
        createdTask: false,
        error: "submit_failed",
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
      }')
    echo "$fail_result" | jq .
    return 1
  fi

  # ========================================================================
  # Phase 7: Record taskId atomically - transition pending -> task_created
  # ========================================================================
  if [ -n "$DB" ] && [ -f "$DB" ]; then
    # Atomic transition: only update if still pending (prevents race with concurrent reviews)
    local update_result
    update_result="$(sqlite3 "$DB" "BEGIN IMMEDIATE; UPDATE processed_comments SET status='task_created', taskId='$new_task_id', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending'; SELECT changes(); COMMIT;" 2>/dev/null)" || {
      echo "ERROR: failed to record taskId for review $review_id" >&2
      return 1
    }
    local rows_updated="${update_result%%$'
'*}"
    if [ "${rows_updated:-0}" -eq 0 ]; then
      # Another process already claimed this review - look up their taskId
      echo "dispatch: review $review_id was claimed by concurrent process, looking up taskId" >&2
      new_task_id="$(sqlite3 "$DB" "SELECT taskId FROM processed_comments WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='task_created' LIMIT 1;" 2>/dev/null || echo "")"
      if [ -z "$new_task_id" ]; then
        # Both processes failed - mark as failed
        sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending';" || {
          echo "ERROR: failed to mark review $review_id as failed (concurrent_claim_failed)" >&2
          return 1
        }
        local fail_result
        fail_result=$(jq -n \
          --arg reviewId "$REVIEW_ID" \
          --arg action "$action" \
          --arg conversationId "$conv_id" \
          --arg parentTaskId "${task_id:-}" \
          --argjson prNumber "$PR_NUMBER" \
          '{
            reviewId: $reviewId,
            action: $action,
            conversationId: $conversationId,
            newTaskId: null,
            parentTaskId: $parentTaskId,
            prNumber: $prNumber,
            createdTask: false,
            error: "concurrent_claim_failed",
            timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
          }')
        echo "$fail_result" | jq .
        return 1
      fi
    fi
  fi

  # ========================================================================
  # Phase 8: Return success with taskId
  # ========================================================================
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
  return 0
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
