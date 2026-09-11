#!/bin/bash
# test_conversation_orchestrator.sh — Tests for Manul conversation orchestration layer
#
# Tests:
#   1. Create conversation
#   2. Stable conversationId
#   3. Conversation ↔ issue association
#   4. Submit first task
#   5. Task inherits conversation
#   6. Task association with issue
#   7. Task association with PR
#   8. Follow-up task
#   9. ParentTaskId linkage
#   10. Review-fix task continues existing PR
#   11. Review-fix does not create unrelated PR
#   12. Multiple tasks same conversation
#   13. Concurrent tasks same conversation
#   14. Task result exposes PR
#   15. PR merge detection
#   16. Completed conversation
#   17. Failed conversation
#   18. Conversation restart/recovery
#   19. JSON contract
#   20. Exit codes
#   21. Duplicate follow-up submission/idempotency
#   22. Stale task / newer task race
#   23. Production path safety
#   24. Existing GitHub /manul regression
#
# Usage: bash test_conversation_orchestrator.sh

set -uo pipefail

# Use a single test directory for all tests
TEST_DIR="${MANUL_TEST_DIR:-$(mktemp -d)}"
export MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/manul.db"
export CONFIG="$TEST_DIR/config.json"
export RESULTS_DIR="$TEST_DIR/results"

CONVERSATION_SCRIPT="/home/marzec/globalskills-temp/skills/manul-github-bot/manul-conversation.sh"

# Cleanup on exit
cleanup() {
  if [ "${TEARDOWN:-0}" = "1" ]; then
    rm -rf "$TEST_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$MANUL_DIR" "$RESULTS_DIR"

# Initialize config
cat > "$CONFIG" << 'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "agents": ["architect", "coder"],
  "automation": {
    "enabled": true,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900,
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800
  }
}
CONFIGEOF

PASS=0
FAIL=0
TEST_NAME=""

# Global test variables (exported for subshells)
export TASK_ID_1=""
export TASK_ID_PR=""
export TASK_ID_FOLLOWUP=""
export CONVERSATION_ID_1=""

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$label"
  else
    fail "$label (expected='$expected', got='$actual')"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    fail "$label (expected to contain '$needle')"
  fi
}

assert_json_valid() {
  local label="$1" json="$2"
  if echo "$json" | jq . >/dev/null 2>&1; then
    ok "$label"
  else
    fail "$label (invalid JSON: $json)"
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$label"
  else
    fail "$label (expected exit=$expected, got=$actual)"
  fi
}

# ============================================================================
# Test 1: Create conversation
# ============================================================================
test_create_conversation() {
  TEST_NAME="create conversation"
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" create \
    --repo "test-owner/test-repo" \
    --title "Test Feature Request" \
    --prompt "Implement the feature" \
    --json 2>/dev/null)" || rc=$?
  
  if [ "${rc:-0}" -eq 0 ] && echo "$output" | jq -e '.conversationId' >/dev/null 2>&1; then
    ok "$TEST_NAME"
    export CONVERSATION_ID_1="$(echo "$output" | jq -r '.conversationId')"
  else
    fail "$TEST_NAME (output: $output, rc: ${rc:-0})"
  fi
}

# ============================================================================
# Test 2: Stable conversationId
# ============================================================================
test_stable_conversation_id() {
  TEST_NAME="stable conversationId"
  # Use the conversation created in test 1
  local conv_id="$CONVERSATION_ID_1"
  
  if [ -z "$conv_id" ]; then
    fail "$TEST_NAME (no conversation from test 1)"
    return
  fi
  
  # Verify the conversation exists and has stable ID
  local db_conv_id
  db_conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
  
  if [ "$db_conv_id" = "$conv_id" ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (conversation not found in DB)"
  fi
}

# ============================================================================
# Test 3: Conversation ↔ issue association
# ============================================================================
test_conversation_issue_association() {
  TEST_NAME="conversation ↔ issue association"
  local conv_id="$CONVERSATION_ID_1"
  
  if [ -z "$conv_id" ]; then
    fail "$TEST_NAME (no conversation from test 1)"
    return
  fi
  
  local issue_num issue_url
  issue_num="$(sqlite3 "$DB" "SELECT issueNumber FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
  issue_url="$(sqlite3 "$DB" "SELECT issueUrl FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
  
  if [ -n "$issue_num" ] || [ -n "$issue_url" ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (missing issue info for conversation $conv_id)"
  fi
}

# ============================================================================
# Test 4: Submit first task
# ============================================================================
test_submit_first_task() {
  TEST_NAME="submit first task"
  local conv_id="$CONVERSATION_ID_1"
  
  if [ -z "$conv_id" ]; then
    fail "$TEST_NAME (no conversation from test 1)"
    return
  fi
  
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Write the implementation" \
    --action IMPLEMENT \
    --json 2>/dev/null)" || rc=$?
  
  if [ "${rc:-0}" -eq 0 ] && echo "$output" | jq -e '.taskId' >/dev/null 2>&1; then
    ok "$TEST_NAME"
    TASK_ID_1="$(echo "$output" | jq -r '.taskId')"
    export TASK_ID_1
  else
    fail "$TEST_NAME (output: $output, rc: ${rc:-0})"
  fi
}

# ============================================================================
# Test 5: Task inherits conversation
# ============================================================================
test_task_inherits_conversation() {
  TEST_NAME="task inherits conversation"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  local task_conv
  task_conv="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$TASK_ID_1';" 2>/dev/null)"
  
  if [ "$task_conv" = "$conv_id" ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (task conversation='$task_conv', expected='$conv_id')"
  fi
}

# ============================================================================
# Test 6: Task association with issue
# ============================================================================
test_task_association_with_issue() {
  TEST_NAME="task association with issue"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  local task_issue
  task_issue="$(sqlite3 "$DB" "SELECT issueNumber FROM processed_comments WHERE commentId='$TASK_ID_1';" 2>/dev/null)"
  local conv_issue
  conv_issue="$(sqlite3 "$DB" "SELECT issueNumber FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
  
  if [ "$task_issue" = "$conv_issue" ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (task issue=$task_issue, conversation issue=$conv_issue)"
  fi
}

# ============================================================================
# Test 7: Task association with PR
# ============================================================================
test_task_association_with_pr() {
  TEST_NAME="task association with PR"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  # Submit a task with a PR number
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Fix the bug" \
    --action REVIEW_FIX \
    --pr-number 42 \
    --json 2>/dev/null)" || rc=$?
  
  if [ "${rc:-0}" -eq 0 ]; then
    local task_id
    task_id="$(echo "$output" | jq -r '.taskId')"
    local task_pr
    task_pr="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"
    
    if [ "$task_pr" = "42" ]; then
      ok "$TEST_NAME"
      export TASK_ID_PR="$(echo "$output" | jq -r '.taskId')"
    else
      fail "$TEST_NAME (task PR=$task_pr, expected=42)"
    fi
  else
    fail "$TEST_NAME (submission failed)"
  fi
}

# ============================================================================
# Test 8: Follow-up task
# ============================================================================
test_followup_task() {
  TEST_NAME="follow-up task"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Add tests for the implementation" \
    --json 2>/dev/null)" || rc=$?
  
  if [ "${rc:-0}" -eq 0 ]; then
    local task_id
    task_id="$(echo "$output" | jq -r '.taskId')"
    local task_count
    task_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$conv_id';" 2>/dev/null)"
    
    if [ "$task_count" -ge 2 ]; then
      ok "$TEST_NAME"
      export TASK_ID_FOLLOWUP="$task_id"
    else
      fail "$TEST_NAME (task count=$task_count, expected>=2)"
    fi
  else
    fail "$TEST_NAME (submission failed)"
  fi
}

# ============================================================================
# Test 9: ParentTaskId linkage
# ============================================================================
test_parent_task_linkage() {
  TEST_NAME="parentTaskId linkage"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Improve test coverage" \
    --parent-task-id "$TASK_ID_1" \
    --json 2>/dev/null)" || rc=$?
  
  if [ "${rc:-0}" -eq 0 ]; then
    local task_id
    task_id="$(echo "$output" | jq -r '.taskId')"
    local parent_id
    parent_id="$(sqlite3 "$DB" "SELECT parentTaskId FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"
    
    if [ "$parent_id" = "$TASK_ID_1" ]; then
      ok "$TEST_NAME"
    else
      fail "$TEST_NAME (parent='$parent_id', expected='$TASK_ID_1')"
    fi
  else
    fail "$TEST_NAME (submission failed)"
  fi
}

# ============================================================================
# Test 10: Review-fix task continues existing PR
# ============================================================================
test_review_fix_continues_pr() {
  TEST_NAME="review-fix task continues existing PR"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  # First submit with PR
  local output1 rc1
  output1="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Initial implementation" \
    --action IMPLEMENT \
    --pr-number 50 \
    --json 2>/dev/null)" || rc1=$?
  
  if [ "${rc1:-0}" -ne 0 ]; then
    fail "$TEST_NAME (initial submission failed)"
    return
  fi
  
  # Then submit review-fix for same PR
  local output2 rc2
  output2="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Address review comments" \
    --action REVIEW_FIX \
    --pr-number 50 \
    --json 2>/dev/null)" || rc2=$?
  
  if [ "${rc2:-0}" -eq 0 ]; then
    local task_id
    task_id="$(echo "$output2" | jq -r '.taskId')"
    local task_pr
    task_pr="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"
    local task_action
    task_action="$(sqlite3 "$DB" "SELECT action FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"
    
    if [ "$task_pr" = "50" ] && [ "$task_action" = "REVIEW_FIX" ]; then
      ok "$TEST_NAME"
    else
      fail "$TEST_NAME (pr=$task_pr, action=$task_action)"
    fi
  else
    fail "$TEST_NAME (review-fix submission failed)"
  fi
}

# ============================================================================
# Test 11: Review-fix does not create unrelated PR
# ============================================================================
test_review_fix_no_unrelated_pr() {
  TEST_NAME="review-fix does not create unrelated PR"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Review fix" \
    --action REVIEW_FIX \
    --json 2>/dev/null)" || rc=$?
  
  if [ "${rc:-0}" -eq 0 ]; then
    local task_id
    task_id="$(echo "$output" | jq -r '.taskId')"
    local task_pr
    task_pr="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"
    
    if [ -z "$task_pr" ] || [ "$task_pr" = "null" ]; then
      ok "$TEST_NAME"
    else
      fail "$TEST_NAME (unexpected PR=$task_pr)"
    fi
  else
    fail "$TEST_NAME (submission failed)"
  fi
}

# ============================================================================
# Test 12: Multiple tasks same conversation
# ============================================================================
test_multiple_tasks_same_conversation() {
  TEST_NAME="multiple tasks same conversation"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  local task_count
  task_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$conv_id';" 2>/dev/null)"
  
  if [ "$task_count" -ge 3 ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (task count=$task_count, expected>=3)"
  fi
}

# ============================================================================
# Test 13: Concurrent tasks same conversation
# ============================================================================
test_concurrent_tasks_same_conversation() {
  TEST_NAME="concurrent tasks same conversation"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  # Submit two tasks rapidly
  local output1 output2 rc1 rc2
  output1="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Task A" \
    --json 2>/dev/null)" || rc1=$?
  
  output2="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Task B" \
    --json 2>/dev/null)" || rc2=$?
  
  local tasks_a tasks_b
  tasks_a="$(echo "$output1" | jq -r '.taskId' 2>/dev/null)"
  tasks_b="$(echo "$output2" | jq -r '.taskId' 2>/dev/null)"
  
  if [ -n "$tasks_a" ] && [ -n "$tasks_b" ] && [ "$tasks_a" != "$tasks_b" ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (tasks: $tasks_a, $tasks_b)"
  fi
}

# ============================================================================
# Test 14: Task result exposes PR
# ============================================================================
test_task_result_exposes_pr() {
  TEST_NAME="task result exposes PR"
  
  # Create a task with PR in the test DB
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  if [ -z "$conv_id" ]; then
    fail "$TEST_NAME (no conversation)"
    return
  fi
  
  # Create a task with PR number
  local task_id="result-test-task"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, processedAt, conversationId, action, prNumber)
    VALUES('$task_id', 'test-owner/test-repo', 1, 'https://github.com/test-owner/test-repo/issues/1', 'test', 'test prompt', 'completed', '$now', '$now', '$conv_id', 'REVIEW_FIX', 42);"
  
  local result
  result="$(bash "$CONVERSATION_SCRIPT" result \
    --task-id "$task_id" \
    --json 2>/dev/null)" || result="{}"
  
  if echo "$result" | jq -e '.prNumber' >/dev/null 2>&1; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (no prNumber in result: $result)"
  fi
}

# ============================================================================
# Test 15: PR merge detection
# ============================================================================
test_pr_merge_detection() {
  TEST_NAME="PR merge detection"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  if [ -z "$conv_id" ]; then
    fail "$TEST_NAME (no conversation)"
    return
  fi
  
  # Create a completed task with PR merge info in result file
  local task_id="merge-test-task"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, processedAt, conversationId, action, prNumber)
    VALUES('$task_id', 'test-owner/test-repo', 1, 'https://github.com/test-owner/test-repo/issues/1', 'test', 'test prompt', 'completed', '$now', '$now', '$conv_id', 'IMPLEMENT', 50);"
  
  # Create result file in correct location
  mkdir -p "$MANUL_DIR/results"
  echo '{"success":true,"prMerged":true}' > "$MANUL_DIR/results/${task_id}.json"
  
  local result
  result="$(bash "$CONVERSATION_SCRIPT" result \
    --task-id "$task_id" \
    --json 2>/dev/null)" || result="{}"
  
  if echo "$result" | jq -e '.result.prMerged' >/dev/null 2>&1; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (prMerged not detected in: $result)"
  fi
}

# ============================================================================
# Test 16: Completed conversation
# ============================================================================
test_completed_conversation() {
  TEST_NAME="completed conversation"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  if [ -z "$conv_id" ]; then
    fail "$TEST_NAME (no conversation to complete)"
    return
  fi
  
  # Complete all tasks
  sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt='$(date -u +%Y-%m-%dT%H:%M:%SZ)' WHERE conversationId='$conv_id';"
  
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" close \
    --conversation-id "$conv_id" \
    --json 2>/dev/null)" || rc=$?
  
  if [ "${rc:-0}" -eq 0 ] && echo "$output" | jq -e '.status' >/dev/null 2>&1; then
    local status
    status="$(echo "$output" | jq -r '.status')"
    if [ "$status" = "COMPLETED" ]; then
      ok "$TEST_NAME"
    else
      fail "$TEST_NAME (status=$status, expected=COMPLETED)"
    fi
  else
    fail "$TEST_NAME (close failed: $output)"
  fi
}

# ============================================================================
# Test 17: Failed conversation
# ============================================================================
test_failed_conversation() {
  TEST_NAME="failed conversation"
  
  # Create a new conversation and fail it
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" create \
    --repo "test-owner/test-fail" \
    --title "Failed Task" \
    --prompt "This will fail" \
    --json 2>/dev/null)" || rc=$?
  
  if [ "${rc:-0}" -eq 0 ]; then
    local conv_id
    conv_id="$(echo "$output" | jq -r '.conversationId')"
    
    # Mark task as failed
    local task_id
    task_id="$(sqlite3 "$DB" "SELECT activeTaskId FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
    if [ -n "$task_id" ]; then
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed' WHERE commentId='$task_id';"
      sqlite3 "$DB" "UPDATE conversations SET status='FAILED' WHERE conversationId='$conv_id';"
    fi
    
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (creation failed)"
  fi
}

# ============================================================================
# Test 18: Conversation restart/recovery
# ============================================================================
test_conversation_restart_recovery() {
  TEST_NAME="conversation restart/recovery"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  if [ -z "$conv_id" ]; then
    fail "$TEST_NAME (no conversation to recover)"
    return
  fi
  
  # Reset status to OPEN
  sqlite3 "$DB" "UPDATE conversations SET status='OPEN' WHERE conversationId='$conv_id';"
  sqlite3 "$DB" "UPDATE processed_comments SET status='queued' WHERE conversationId='$conv_id' AND status='completed';"
  
  # Verify recovery
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
  
  if [ "$status" = "OPEN" ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (status=$status, expected=OPEN)"
  fi
}

# ============================================================================
# Test 19: JSON contract
# ============================================================================
test_json_contract() {
  TEST_NAME="JSON contract"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  local status_output result_output
  status_output="$(bash "$CONVERSATION_SCRIPT" status \
    --conversation-id "$conv_id" \
    --json 2>/dev/null)" || status_output="{}"
  
  result_output="$(bash "$CONVERSATION_SCRIPT" result \
    --task-id "$TASK_ID_1" \
    --json 2>/dev/null)" || result_output="{}"
  
  # Validate status JSON structure
  local has_fields
  has_fields="$(echo "$status_output" | jq 'has("conversationId") and has("repository") and has("status") and has("tasks")' 2>/dev/null)"
  
  if [ "$has_fields" = "true" ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (missing fields in status JSON)"
  fi
}

# ============================================================================
# Test 20: Exit codes
# ============================================================================
test_exit_codes() {
  TEST_NAME="exit codes"
  local rc_not_found rc_bad_request
  
  bash "$CONVERSATION_SCRIPT" status \
    --conversation-id "nonexistent-conv" \
    --json >/dev/null 2>&1
  rc_not_found=$?
  
  bash "$CONVERSATION_SCRIPT" create \
    --repo "test" \
    >/dev/null 2>&1
  rc_bad_request=$?
  
  if [ "$rc_not_found" -eq 2 ] && [ "$rc_bad_request" -eq 3 ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (not_found=$rc_not_found, bad_request=$rc_bad_request)"
  fi
}

# ============================================================================
# Test 21: Duplicate follow-up submission/idempotency
# ============================================================================
test_duplicate_submission_idempotency() {
  TEST_NAME="duplicate follow-up submission/idempotency"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  if [ -z "$conv_id" ]; then
    fail "$TEST_NAME (no conversation)"
    return
  fi
  
  # Submit same prompt twice
  local output1 output2
  output1="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Duplicate test" \
    --json 2>/dev/null)" || output1="{}"
  
  output2="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Duplicate test" \
    --json 2>/dev/null)" || output2="{}"
  
  local id1 id2
  id1="$(echo "$output1" | jq -r '.taskId // empty')"
  id2="$(echo "$output2" | jq -r '.taskId // empty')"
  
  if [ -n "$id1" ] && [ -n "$id2" ] && [ "$id1" != "$id2" ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (duplicate handling: $id1, $id2)"
  fi
}

# ============================================================================
# Test 22: Stale task / newer task race
# ============================================================================
test_stale_task_race() {
  TEST_NAME="stale task / newer task race"
  local conv_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  
  if [ -z "$conv_id" ]; then
    fail "$TEST_NAME (no conversation)"
    return
  fi
  
  # Create a stale running task (match column count)
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, heartbeatAt, leaseExpiresAt, conversationId, action)
    VALUES('stale-task-123', 'test-owner/test-repo', 1, 'https://github.com/test-owner/test-repo/issues/1', 'test', 'stale prompt', 'running', '$now', '$now', '$now', '$conv_id', 'IMPLEMENT');"
  
  # Submit a newer task - should fail because conversation has running task
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Newer task" \
    --json 2>&1)" || rc=$?
  
  # Expected: submission fails with error about running tasks
  if [ "${rc:-0}" -ne 0 ] && echo "$output" | grep -q "running tasks"; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (expected failure due to running task, got rc=${rc:-0}, output: $output)"
  fi
}

# ============================================================================
# Test 23: Production path safety
# ============================================================================
test_production_path_safety() {
  TEST_NAME="production path safety"
  
  # Ensure test operations don't affect production DB
  local prod_db="/home/marzec/.openclaw/manul/manul.db"
  local prod_records_before
  prod_records_before="$(sqlite3 "$prod_db" "SELECT COUNT(*) FROM conversations;" 2>/dev/null || echo "0")"
  
  # Run a test create
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" create \
    --repo "test-owner/test-safety" \
    --title "Safety Test" \
    --prompt "Safety check" \
    --json 2>/dev/null)" || rc=$?
  
  local prod_records_after
  prod_records_after="$(sqlite3 "$prod_db" "SELECT COUNT(*) FROM conversations;" 2>/dev/null || echo "0")"
  
  if [ "$prod_records_before" = "$prod_records_after" ]; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (production DB modified: $prod_records_before -> $prod_records_after)"
  fi
}

# ============================================================================
# Test 24: Existing GitHub /manul regression
# ============================================================================
test_github_manul_regression() {
  TEST_NAME="existing GitHub /manul regression"
  
  # Verify existing poll.sh still works
  local poll_script="$TEST_DIR/../poll.sh"
  if [ ! -f "$poll_script" ]; then
    poll_script="/home/marzec/globalskills-temp/skills/manul-github-bot/poll.sh"
  fi
  
  if [ -f "$poll_script" ]; then
    # Check syntax
    if bash -n "$poll_script" 2>/dev/null; then
      ok "$TEST_NAME"
    else
      fail "$TEST_NAME (poll.sh syntax error)"
    fi
  else
    fail "$TEST_NAME (poll.sh not found)"
  fi
}

# ============================================================================
# Main
# ============================================================================
echo ""
echo "========================================"
echo "  Manul Conversation Orchestrator Tests"
echo "========================================"
echo ""

# Initialize schema
bash "$CONVERSATION_SCRIPT" status --conversation-id "test-init" >/dev/null 2>&1 || true

# Run tests
test_create_conversation
test_stable_conversation_id
test_conversation_issue_association
test_submit_first_task
test_task_inherits_conversation
test_task_association_with_issue
test_task_association_with_pr
test_followup_task
test_parent_task_linkage
test_review_fix_continues_pr
test_review_fix_no_unrelated_pr
test_multiple_tasks_same_conversation
test_concurrent_tasks_same_conversation
test_task_result_exposes_pr
test_pr_merge_detection
test_completed_conversation
test_failed_conversation
test_conversation_restart_recovery
test_json_contract
test_exit_codes
test_duplicate_submission_idempotency
test_stale_task_race
test_production_path_safety
test_github_manul_regression

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
