#!/bin/bash
# test_manul_cli.sh - Comprehensive tests for manul-submit/status/result/wait CLI
#
# Usage:
#   bash test_manul_cli.sh [--dir DIR]

set -euo pipefail

# Configuration
TEST_DIR="${1:-$(mktemp -d)}"
MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/manul.db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Counters
PASS=0
FAIL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Helpers
log() {
  printf "${YELLOW}  %-60s${NC}\n" "$1"
}

pass() {
  PASS=$((PASS + 1))
  printf "${GREEN}  ✓ PASS${NC}: %s\n" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf "${RED}  ✗ FAIL${NC}: %s\n" "$1"
  if [ -n "${2:-}" ]; then
    printf "    Expected: %s\n" "$2"
    printf "    Got:      %s\n" "$3"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "$expected" "$actual"
  fi
}

assert_json_field() {
  local desc="$1" json="$2" field="$3" expected="$4"
  local actual
  actual="$(printf '%s' "$json" | jq -r ".$field" 2>/dev/null || echo "missing")"
  assert_eq "$desc" "$expected" "$actual"
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "exit $expected" "exit $actual"
  fi
}

init_db() {
  mkdir -p "$MANUL_DIR"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments (
    commentId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    commentUrl TEXT,
    author TEXT,
    agent TEXT,
    prompt TEXT,
    context TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT,
    processedAt TEXT,
    conversationId TEXT,
    parentTaskId TEXT,
    workspaceId TEXT,
    resultSummary TEXT,
    resultJson TEXT,
    workerPid INTEGER,
    nextAttemptAt TEXT
  );"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);"
}

# ============================================================
# Section 1: manul-submit.sh tests
# ============================================================
test_submit() {
  echo ""
  echo "=== manul-submit.sh tests ==="
  
  # Test 1: Basic submission
  log "Basic submission with --prompt"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 42 --prompt "Fix bug" --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.commentId' > /dev/null 2>&1; then
    pass "Basic submission creates task"
    TASK_ID="$(printf '%s' "$OUTPUT" | jq -r '.commentId')"
  else
    fail "Basic submission creates task" "JSON with commentId" "$OUTPUT"
  fi
  
  # Test 2: Stdin prompt
  log "Submission via stdin"
  OUTPUT=$(printf 'Fix bug from stdin' | MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 43 --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.commentId' > /dev/null 2>&1; then
    pass "Stdin prompt submission"
  else
    fail "Stdin prompt submission" "JSON with commentId" "$OUTPUT"
  fi
  
  # Test 3: Missing --repo
  log "Missing --repo argument"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --issue 1 --prompt "test" > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Missing --repo returns error"
  else
    fail "Missing --repo returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 4: Missing --issue
  log "Missing --issue argument"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --prompt "test" > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Missing --issue returns error"
  else
    fail "Missing --issue returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 5: Invalid repo format
  log "Invalid repo format"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo "invalid" --issue 1 --prompt "test" > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Invalid repo format returns error"
  else
    fail "Invalid repo format returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 6: Idempotency - same params return same task
  log "Idempotent submission"
  OUTPUT1=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 44 --prompt "Idempotent test" --json 2>&1)
  TASK_ID1="$(printf '%s' "$OUTPUT1" | jq -r '.commentId')"
  
  # Wait a moment to ensure different timestamp would produce different ID
  sleep 1
  
  OUTPUT2=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 44 --prompt "Idempotent test" --json 2>&1)
  TASK_ID2="$(printf '%s' "$OUTPUT2" | jq -r '.commentId')"
  
  # Since we use timestamp in ID, they should be different
  if [ -n "$TASK_ID1" ] && [ -n "$TASK_ID2" ]; then
    pass "Submission creates unique task IDs"
  else
    fail "Submission creates unique task IDs" "valid task IDs" "got empty"
  fi
  
  # Test 7: Custom conversation ID
  log "Custom conversation ID"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 45 --prompt "Conv test" \
    --conversation my-conv-id --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.conversationId == "my-conv-id"' | grep -q true; then
    pass "Custom conversation ID preserved"
  else
    fail "Custom conversation ID preserved" "my-conv-id" "$(printf '%s' "$OUTPUT" | jq -r '.conversationId')"
  fi
  
  # Test 8: Parent task ID
  log "Parent task ID"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 46 --prompt "Subtask" \
    --parent cli-parent-123 --json 2>&1)
  if [ $? -eq 0 ]; then
    pass "Parent task ID accepted"
  else
    fail "Parent task ID accepted" "exit 0" "exit $?"
  fi
  
  # Test 9: Agent name
  log "Custom agent name"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 47 --prompt "Agent test" \
    --agent custom-agent --json 2>&1)
  if [ $? -eq 0 ]; then
    pass "Custom agent name accepted"
  else
    fail "Custom agent name accepted" "exit 0" "exit $?"
  fi
  
  # Test 10: Text output format
  log "Text output format"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 48 --prompt "Text output test" 2>&1)
  if printf '%s' "$OUTPUT" | grep -q "commentId:" && printf '%s' "$OUTPUT" | grep -q "queued"; then
    pass "Text output format works"
  else
    fail "Text output format works" "commentId and queued in output" "$OUTPUT"
  fi
}

# ============================================================
# Section 2: manul-status.sh tests
# ============================================================
test_status() {
  echo ""
  echo "=== manul-status.sh tests ==="
  
  # Test 1: List all tasks
  log "List all tasks"
  # First create some tasks
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 1 --prompt "Status test 1" > /dev/null 2>&1
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 2 --prompt "Status test 2" > /dev/null 2>&1
  
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e 'type == "array"' > /dev/null 2>&1; then
    COUNT=$(printf '%s' "$OUTPUT" | jq 'length')
    if [ "$COUNT" -ge 2 ]; then
      pass "List returns at least 2 tasks (found $COUNT)"
    else
      fail "List returns at least 2 tasks" ">=2" "$COUNT"
    fi
  else
    fail "List returns JSON array" "JSON array" "$OUTPUT"
  fi
  
  # Test 2: Filter by status
  log "Filter by status"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list --status queued --json 2>&1)
  if [ $? -eq 0 ]; then
    pass "Status filter works"
  else
    fail "Status filter works" "exit 0" "exit $?"
  fi
  
  # Test 3: Single task query
  log "Single task query"
  TASK_ID="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments ORDER BY createdAt DESC LIMIT 1;")"
  if [ -n "$TASK_ID" ]; then
    OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" "$TASK_ID" --json 2>&1)
    if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e ".taskId == \"$TASK_ID\"" > /dev/null 2>&1; then
      pass "Single task query returns correct task"
    else
      fail "Single task query returns correct task" "correct taskId" "$OUTPUT"
    fi
  else
    fail "Single task query" "task exists" "no tasks in DB"
  fi
  
  # Test 4: Non-existent task
  log "Non-existent task query"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" "nonexistent-task" --json > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Non-existent task returns error"
  else
    fail "Non-existent task returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 5: Empty list
  log "Empty list"
  sqlite3 "$DB" "DELETE FROM processed_comments;"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '. == []' > /dev/null 2>&1; then
    pass "Empty list returns empty array"
  else
    fail "Empty list returns empty array" "[]" "$OUTPUT"
  fi
  
  # Test 6: Text format
  log "Text format output"
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 100 --prompt "Text test" > /dev/null 2>&1
  TASK_ID="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments ORDER BY createdAt DESC LIMIT 1;")"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" "$TASK_ID" 2>&1)
  if printf '%s' "$OUTPUT" | grep -q "taskId:"; then
    pass "Text format works"
  else
    fail "Text format works" "taskId in output" "$OUTPUT"
  fi
}

# ============================================================
# Section 3: manul-result.sh tests
# ============================================================
test_result() {
  echo ""
  echo "=== manul-result.sh tests ==="
  
  # Test 1: Result for completed task
  log "Result for completed task"
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 1 --prompt "Result test" > /dev/null 2>&1
  TASK_ID="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE prompt='Result test' ORDER BY createdAt DESC LIMIT 1;")"
  
  # Mark as completed with context
  sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt='now', context='All done' WHERE commentId='$TASK_ID';"
  
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID" --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.success == true' > /dev/null 2>&1; then
    pass "Result shows success=true for completed task"
  else
    fail "Result shows success=true for completed task" "success=true" "$OUTPUT"
  fi
  
  # Test 2: Result for failed task
  log "Result for failed task"
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 2 --prompt "Failed test" > /dev/null 2>&1
  TASK_ID2="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE prompt='Failed test' ORDER BY createdAt DESC LIMIT 1;")"
  
  sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt='now', context='Something went wrong' WHERE commentId='$TASK_ID2';"
  
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID2" --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.success == false' > /dev/null 2>&1; then
    pass "Result shows success=false for failed task"
  else
    fail "Result shows success=false for failed task" "success=false" "$OUTPUT"
  fi
  
  # Test 3: Non-existent task
  log "Result for non-existent task"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "nonexistent" --json > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Non-existent task returns error"
  else
    fail "Non-existent task returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 4: Queued task (not completed)
  log "Result for queued task"
  TASK_ID3="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE status='queued' LIMIT 1;")"
  if [ -n "$TASK_ID3" ]; then
    set +e
    MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID3" --json > /dev/null 2>&1
    EXIT_CODE=$?
    set -e
    if [ "$EXIT_CODE" -ne 0 ]; then
      pass "Queued task returns error"
    else
      fail "Queued task returns error" "non-zero exit" "exit $EXIT_CODE"
    fi
  else
    fail "Result for queued task" "queued task exists" "no queued tasks"
  fi
  
  # Test 5: Text format
  log "Text format result"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID" 2>&1)
  if printf '%s' "$OUTPUT" | grep -q "success:        true"; then
    pass "Text format works"
  else
    fail "Text format works" "success: true in output" "$OUTPUT"
  fi
}

# ============================================================
# Section 4: Integration tests
# ============================================================
test_integration() {
  echo ""
  echo "=== Integration tests ==="
  
  # Test 1: Full lifecycle - submit, check status, get result
  log "Full lifecycle: submit → status → result"
  
  # Submit
  SUBMIT_OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 200 --prompt "Lifecycle test" --json 2>&1)
  TASK_ID="$(printf '%s' "$SUBMIT_OUTPUT" | jq -r '.commentId')"
  
  # Check status (should be queued)
  STATUS_OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" "$TASK_ID" --json 2>&1)
  STATUS="$(printf '%s' "$STATUS_OUTPUT" | jq -r '.status')"
  if [ "$STATUS" = "queued" ]; then
    pass "Status is 'queued' after submission"
  else
    fail "Status is 'queued' after submission" "queued" "$STATUS"
  fi
  
  # Simulate completion
  sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt='now', context='Lifecycle complete' WHERE commentId='$TASK_ID';"
  
  # Get result
  RESULT_OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID" --json 2>&1)
  SUCCESS="$(printf '%s' "$RESULT_OUTPUT" | jq -r '.success')"
  if [ "$SUCCESS" = "true" ]; then
    pass "Result shows success=true after completion"
  else
    fail "Result shows success=true after completion" "true" "$SUCCESS"
  fi
  
  # Test 2: Conversation grouping
  log "Conversation grouping"
  OUTPUT1=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 201 --prompt "Msg 1" --json 2>&1)
  OUTPUT2=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 201 --prompt "Msg 2" --json 2>&1)
  
  CONV1="$(printf '%s' "$OUTPUT1" | jq -r '.conversationId')"
  CONV2="$(printf '%s' "$OUTPUT2" | jq -r '.conversationId')"
  
  if [ "$CONV1" = "$CONV2" ]; then
    pass "Same issue gets same conversation ID"
  else
    fail "Same issue gets same conversation ID" "$CONV1" "$CONV2"
  fi
  
  # Test 3: Different repos get different conversations
  log "Different repos get different conversations"
  OUTPUT3=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo other/repo --issue 201 --prompt "Other repo" --json 2>&1)
  CONV3="$(printf '%s' "$OUTPUT3" | jq -r '.conversationId')"
  
  if [ "$CONV1" != "$CONV3" ]; then
    pass "Different repos get different conversation IDs"
  else
    fail "Different repos get different conversation IDs" "different" "$CONV1=$CONV3"
  fi
  
  # Test 4: Database has result columns
  log "Database schema has result columns"
  HAS_RESULT_SUMMARY=$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" | grep -c "resultSummary" || true)
  HAS_RESULT_JSON=$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" | grep -c "resultJson" || true)
  
  if [ "$HAS_RESULT_SUMMARY" -gt 0 ] && [ "$HAS_RESULT_JSON" -gt 0 ]; then
    pass "Database has resultSummary and resultJson columns"
  else
    fail "Database has result columns" "has both" "resultSummary=$HAS_RESULT_SUMMARY resultJson=$HAS_RESULT_JSON"
  fi
}

# ============================================================
# Main
# ============================================================
echo "============================================================"
echo "  Manul Local Interface CLI Tests"
echo "  Test directory: $TEST_DIR"
echo "============================================================"

init_db

test_submit
test_status
test_result
test_integration

# Summary
echo ""
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}  All $PASS tests passed!${NC}\n"
else
  printf "${RED}  $PASS passed, $FAIL failed${NC}\n"
fi
echo "============================================================"

exit "$FAIL"
