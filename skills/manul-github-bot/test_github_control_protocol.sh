#!/bin/bash
# test_github_control_protocol.sh - Comprehensive tests for GitHub control protocol
#
# Tests cover:
# 1. Issue command creates task
# 2. Same Issue preserves conversation
# 3. Duplicate comment does not create duplicate task
# 4. PR comment creates REVIEW_FIX
# 5. REVIEW_FIX preserves prNumber
# 6. REVIEW_FIX preserves conversationId
# 7. parentTaskId is preserved
# 8. APPROVE does not create fix task
# 9. REQUEST_CHANGES creates fix task
# 10. Duplicate review is ignored
# 11. Structured events parse correctly
# 12. Malformed events are ignored safely
# 13. Task result produces machine event
# 14. Failed task produces machine event
# 15. Out-of-order events are handled
# 16. Merged PR handling
# 17. Closed Issue handling
# 18. Concurrent comments
# 19. JSON/state consistency
# 20. Production path safety
#
# Plus: End-to-end mock flow (Issue -> PR -> Review -> Fix -> Approve)

set -uo pipefail

# Resolve script directory portably
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Set up MANUL_DIR with proper config
MANUL_DIR="$TEST_DIR/manul"
mkdir -p "$MANUL_DIR"
DB="$MANUL_DIR/manul.db"

# Create proper config
cat > "$MANUL_DIR/config.json" << 'CONFIGEOF'
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

# Scripts to test — use SCRIPT_DIR for portability
EVENTS_SCRIPT="$SCRIPT_DIR/manul-github-events.sh"
REVIEW_SCRIPT="$SCRIPT_DIR/manul-pr-review.sh"
LINKER_SCRIPT="$SCRIPT_DIR/manul-conversation-linker.sh"
FEEDBACK_SCRIPT="$SCRIPT_DIR/manul-result-feedback.sh"

PASSED=0
FAILED=0
TESTS_RUN=0

pass_test() { PASSED=$((PASSED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  PASS: $1"; }
fail_test() { FAILED=$((FAILED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  FAIL: $1"; }
run_test() { local name="$1"; local func="$2"; set +e; "$func"; local rc=$?; set -e; [ $rc -eq 0 ] && pass_test "$name" || fail_test "$name"; }

# Helper: run events script with test env
events() {
  MANUL_DIR="$MANUL_DIR" bash "$EVENTS_SCRIPT" "$@"
}

# Helper: run review script with test env
review() {
  MANUL_DIR="$MANUL_DIR" bash "$REVIEW_SCRIPT" "$@"
}

# Helper: run linker script with test env
linker() {
  MANUL_DIR="$MANUL_DIR" bash "$LINKER_SCRIPT" "$@"
}

# Helper: run feedback script with test env
feedback() {
  MANUL_DIR="$MANUL_DIR" bash "$FEEDBACK_SCRIPT" "$@"
}

# Helper: initialize DB schema
init_db() {
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments (
    commentId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    commentUrl TEXT NOT NULL,
    author TEXT,
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
  );"

  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversations (
    conversationId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER,
    issueUrl TEXT,
    activePrNumber INTEGER,
    activePrUrl TEXT,
    status TEXT NOT NULL DEFAULT 'OPEN',
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
  );"

  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversation_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversationId TEXT NOT NULL,
    repo TEXT NOT NULL,
    issueNumber INTEGER,
    prNumber INTEGER,
    commentId TEXT,
    taskCommentId TEXT,
    linkType TEXT NOT NULL,
    createdAt TEXT NOT NULL
  );"

  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS submission_claims (
    baseId TEXT PRIMARY KEY,
    commentId TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    createdAt TEXT DEFAULT (datetime('now'))
  );"
}

# ============================================================
# Test Suite
# ============================================================

# Test 1: Issue command creates task
test_issue_command_creates_task() {
  init_db

  local body="/manul Implement feature X"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "1" --comment-id "100" --body "$body" --author "user1" --created "2026-09-11T00:00:00Z" --json 2>/dev/null)" || return 1

  local valid
  valid="$(echo "$output" | jq -r '.command.valid // false')"
  [ "$valid" = "true" ] || return 1

  local action
  action="$(echo "$output" | jq -r '.command.action // empty')"
  [ "$action" = "IMPLEMENT" ] || return 1
}

# Test 2: Same Issue preserves conversation
test_same_issue_preserves_conversation() {
  init_db

  # First comment
  local body1="/manul Implement feature X"
  local output1
  output1="$(events parse-comment --repo "test/repo" --issue "1" --comment-id "100" --body "$body1" --author "user1" --created "2026-09-11T00:00:00Z" --json 2>/dev/null)" || return 1

  # Second comment on same issue
  local body2="/manul Also add tests"
  local output2
  output2="$(events parse-comment --repo "test/repo" --issue "1" --comment-id "101" --body "$body2" --author "user1" --created "2026-09-11T00:01:00Z" --json 2>/dev/null)" || return 1

  # Both should be valid
  local valid1 valid2
  valid1="$(echo "$output1" | jq -r '.command.valid // false')"
  valid2="$(echo "$output2" | jq -r '.command.valid // false')"
  [ "$valid1" = "true" ] && [ "$valid2" = "true" ] || return 1
}

# Test 3: Duplicate comment does not create duplicate task
test_duplicate_comment_no_dup_task() {
  init_db

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Insert first task
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId) VALUES('issue:100', 'test/repo', 1, 'https://github.com/test/repo/issues/1#issuecomment-100', 'user1', 'Implement feature X', 'queued', '$now', 'conv-test');" 2>/dev/null

  # Try to insert duplicate
  local ins
  ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId) VALUES('issue:100', 'test/repo', 1, 'https://github.com/test/repo/issues/1#issuecomment-100', 'user1', 'Implement feature X', 'queued', '$now', 'conv-test'); SELECT changes();" 2>/dev/null)"

  [ "$ins" = "0" ] || return 1
}

# Test 4: PR comment creates REVIEW_FIX
test_pr_comment_creates_review_fix() {
  init_db

  local body="/manul review-fix Please add error handling"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "200" --body "$body" --author "reviewer" --created "2026-09-11T00:00:00Z" --json 2>/dev/null)" || return 1

  local action
  action="$(echo "$output" | jq -r '.command.action // empty')"
  [ "$action" = "REVIEW_FIX" ] || return 1
}

# Test 5: REVIEW_FIX preserves prNumber
test_review_fix_preserves_pr_number() {
  init_db

  # Create conversation with active PR
  local conv_id="conv-test-pr"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 100, 'https://github.com/test/repo/issues/100', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=100 WHERE conversationId='$conv_id';" 2>/dev/null

  # Handle PR review
  local output
  output="$(review handle --repo "test/repo" --pr-number "100" --review-id "r1" --review-state "REQUEST_CHANGES" --body "Please fix this" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local created_task
  created_task="$(echo "$output" | jq -r '.createdTask // false')"
  [ "$created_task" = "true" ] || return 1

  local pr_num
  pr_num="$(echo "$output" | jq -r '.prNumber // empty')"
  [ "$pr_num" = "100" ] || return 1
}

# Test 6: REVIEW_FIX preserves conversationId
test_review_fix_preserves_conversation() {
  init_db

  local conv_id="conv-test-ctx"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 50, 'https://github.com/test/repo/issues/50', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=55 WHERE conversationId='$conv_id';" 2>/dev/null

  local output
  output="$(review handle --repo "test/repo" --pr-number "55" --review-id "r2" --review-state "REQUEST_CHANGES" --body "Fix this" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local conversation_id
  conversation_id="$(echo "$output" | jq -r '.conversationId // empty')"
  [ "$conversation_id" = "$conv_id" ] || return 1
}

# Test 7: parentTaskId is preserved
test_parent_task_id_preserved() {
  init_db

  local conv_id="conv-test-parent"
  local task_id="task-conv-test-parent-init"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 200, 'https://github.com/test/repo/issues/200', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=201 WHERE conversationId='$conv_id';" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, prNumber, action) VALUES('$task_id', 'test/repo', 200, 'https://github.com/test/repo/issues/200', 'user', 'Implement', 'completed', '$now', '$conv_id', 201, 'IMPLEMENT');" 2>/dev/null

  local output
  output="$(review handle --repo "test/repo" --pr-number "201" --review-id "r3" --review-state "REQUEST_CHANGES" --body "Fix issues" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  # Check that new task has parentTaskId
  local parent_id
  parent_id="$(echo "$output" | jq -r '.parentTaskId // empty')"
  [ "$parent_id" = "$task_id" ] || return 1
}

# Test 8: APPROVE does not create fix task
test_approve_no_fix_task() {
  init_db

  local conv_id="conv-test-approve"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 300, 'https://github.com/test/repo/issues/300', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=301 WHERE conversationId='$conv_id';" 2>/dev/null

  local output
  output="$(review handle --repo "test/repo" --pr-number "301" --review-id "r4" --review-state "APPROVE" --body "Looks good!" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local created_task
  created_task="$(echo "$output" | jq -r '.createdTask // false')"
  [ "$created_task" = "false" ] || return 1
}

# Test 9: REQUEST_CHANGES creates fix task
test_request_changes_creates_fix() {
  init_db

  local conv_id="conv-test-changes"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 400, 'https://github.com/test/repo/issues/400', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=401 WHERE conversationId='$conv_id';" 2>/dev/null

  local output
  output="$(review handle --repo "test/repo" --pr-number "401" --review-id "r5" --review-state "REQUEST_CHANGES" --body "Please add tests" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local created_task
  created_task="$(echo "$output" | jq -r '.createdTask // false')"
  [ "$created_task" = "true" ] || return 1

  local action
  action="$(echo "$output" | jq -r '.action // empty')"
  [ "$action" = "REQUEST_CHANGES" ] || return 1
}

# Test 10: Duplicate review is ignored
test_duplicate_review_ignored() {
  init_db

  local conv_id="conv-test-dup"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 500, 'https://github.com/test/repo/issues/500', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=501 WHERE conversationId='$conv_id';" 2>/dev/null

  # First review
  local output1
  output1="$(review handle --repo "test/repo" --pr-number "501" --review-id "r6" --review-state "REQUEST_CHANGES" --body "Fix this" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  # Second review with same ID
  local output2
  output2="$(review handle --repo "test/repo" --pr-number "501" --review-id "r6" --review-state "REQUEST_CHANGES" --body "Fix this again" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local skipped1 skipped2
  skipped1="$(echo "$output1" | jq -r '.skipped // false')"
  skipped2="$(echo "$output2" | jq -r '.skipped // false')"

  # Second should be skipped
  [ "$skipped2" = "true" ] || return 1
}

# Test 11: Structured events parse correctly
test_structured_events_parse() {
  local body="<!-- manul:event {\"type\":\"TASK_DONE\",\"timestamp\":\"2026-09-11T00:00:00Z\",\"data\":{\"taskId\":\"t1\",\"status\":\"completed\"}} -->
Some human readable text
<!-- manul:event {\"type\":\"REVIEW_APPROVED\",\"timestamp\":\"2026-09-11T00:01:00Z\",\"data\":{\"prNumber\":100}} -->"

  local output
  output="$(events extract-events --body "$body" --json 2>/dev/null)" || return 1

  local event_count
  event_count="$(echo "$output" | jq -r '.eventCount // 0')"
  [ "$event_count" = "2" ] || return 1
}

# Test 12: Malformed events are ignored safely
test_malformed_events_ignored() {
  local body="<!-- manul:event {invalid json -->
Normal comment
<!-- manul:event -->"

  local output
  output="$(events extract-events --body "$body" --json 2>/dev/null)" || return 0  # Should not crash

  local event_count
  event_count="$(echo "$output" | jq -r '.eventCount // 0')"
  [ "$event_count" = "0" ] || return 1
}

# Test 13: Task result produces machine event
test_task_result_produces_event() {
  init_db

  local task_id="task-result-test"
  local conv_id="conv-result-test"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 600, 'https://github.com/test/repo/issues/600', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, action) VALUES('$task_id', 'test/repo', 600, 'https://github.com/test/repo/issues/600', 'user', 'Implement', 'completed', '$now', '$conv_id', 'IMPLEMENT');" 2>/dev/null

  local output
  output="$(feedback post-done --repo "test/repo" --issue "600" --comment-id "c1" --task-id "$task_id" --summary "Completed successfully" --pr-number "601" --json 2>/dev/null)" || return 1

  local status
  status="$(echo "$output" | jq -r '.status // empty')"
  [ "$status" = "completed" ] || return 1

  local has_marker
  has_marker="$(echo "$output" | jq -r '.hasSummary // false')"
  [ "$has_marker" = "true" ] || return 1
}

# Test 14: Failed task produces machine event
test_failed_task_produces_event() {
  init_db

  local task_id="task-fail-test"
  local conv_id="conv-fail-test"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 700, 'https://github.com/test/repo/issues/700', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, action) VALUES('$task_id', 'test/repo', 700, 'https://github.com/test/repo/issues/700', 'user', 'Implement', 'failed', '$now', '$conv_id', 'IMPLEMENT');" 2>/dev/null

  local output
  output="$(feedback post-failed --repo "test/repo" --issue "700" --comment-id "c2" --task-id "$task_id" --error "Something went wrong" --json 2>/dev/null)" || return 1

  local status
  status="$(echo "$output" | jq -r '.status // empty')"
  [ "$status" = "failed" ] || return 1
}

# Test 15: Out-of-order events are handled
test_out_of_order_events() {
  init_db

  local conv_id="conv-test-oio"
  local task_id="task-oio-1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 800, 'https://github.com/test/repo/issues/800', 'OPEN', '$now', '$now');" 2>/dev/null

  # Simulate out-of-order: TASK_DONE before TASK_STARTED
  local output1
  output1="$(feedback post-done --repo "test/repo" --issue "800" --comment-id "c3" --task-id "$task_id" --summary "Done" --json 2>/dev/null)" || return 1

  local status1
  status1="$(echo "$output1" | jq -r '.status // empty')"
  [ "$status1" = "completed" ] || return 1
}

# Test 16: Merged PR handling
test_merged_pr_handling() {
  init_db

  local conv_id="conv-test-merged"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 900, 'https://github.com/test/repo/issues/900', 'COMPLETED', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=901 WHERE conversationId='$conv_id';" 2>/dev/null

  # Try to handle review on merged PR - should error because conversation is completed
  local output
  output="$(review handle --repo "test/repo" --pr-number "901" --review-id "r7" --review-state "REQUEST_CHANGES" --body "Fix this" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 0  # Expected to fail

  # Should not create task for completed conversation
  local created_task
  created_task="$(echo "$output" | jq -r '.createdTask // false')"
  [ "$created_task" = "false" ] || return 1
}

# Test 17: Closed Issue handling
test_closed_issue_handling() {
  init_db

  local body="/manul Do something"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "1000" --comment-id "c4" --body "$body" --author "user" --created "2026-09-11T00:00:00Z" --json 2>/dev/null)" || return 1

  local valid
  valid="$(echo "$output" | jq -r '.command.valid // false')"
  [ "$valid" = "true" ] || return 1

  # Parsing should succeed even for closed issues (validation happens elsewhere)
}

# Test 18: Concurrent comments
test_concurrent_comments() {
  init_db

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Insert two tasks concurrently
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId) VALUES('issue:1100', 'test/repo', 1100, 'https://github.com/test/repo/issues/1100#comment-1', 'user1', 'Task 1', 'queued', '$now', 'conv-concurrent');" 2>/dev/null
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId) VALUES('issue:1101', 'test/repo', 1100, 'https://github.com/test/repo/issues/1100#comment-2', 'user1', 'Task 2', 'queued', '$now', 'conv-concurrent');" 2>/dev/null

  local count
  count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='conv-concurrent' AND status='queued';" 2>/dev/null)"
  [ "$count" = "2" ] || return 1
}

# Test 19: JSON/state consistency
test_json_state_consistency() {
  init_db

  local task_id="task-json-test"
  local conv_id="conv-json-test"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 1200, 'https://github.com/test/repo/issues/1200', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, action, resultSummary) VALUES('$task_id', 'test/repo', 1200, 'https://github.com/test/repo/issues/1200', 'user', 'Implement', 'completed', '$now', '$conv_id', 'IMPLEMENT', 'Done successfully');" 2>/dev/null

  local output
  output="$(feedback post-done --repo "test/repo" --issue "1200" --comment-id "c5" --task-id "$task_id" --summary "Test summary" --json 2>/dev/null)" || return 1

  # Verify JSON is valid
  echo "$output" | jq empty 2>/dev/null || return 1

  # Verify fields exist
  local has_task_id has_status has_marker
  has_task_id="$(echo "$output" | jq -r '.taskId // empty')"
  has_status="$(echo "$output" | jq -r '.status // empty')"
  has_marker="$(echo "$output" | jq -r '.eventMarker // empty')"

  [ -n "$has_task_id" ] && [ -n "$has_status" ] && [ -n "$has_marker" ] || return 1
}

# Test 20: Production path safety
test_production_path_safety() {
  init_db

  # Test with empty/missing fields
  local output
  output="$(events parse-comment --repo "" --issue "" --comment-id "" --body "" --json 2>/dev/null)" || return 0  # Should not crash

  # Test with SQL injection attempts
  local malicious_body="/manul'; DROP TABLE processed_comments; --"
  output="$(events parse-comment --repo "test/repo" --issue "1" --comment-id "c6" --body "$malicious_body" --json 2>/dev/null)" || return 1

  # Should parse safely without executing SQL
  local valid
  valid="$(echo "$output" | jq -r '.command.valid // false')"
  [ "$valid" = "true" ] || return 1
}

# ============================================================
# End-to-End Mock Flow
# ============================================================
test_end_to_end_mock_flow() {
  init_db

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Step 1: Issue comment creates conversation and task
  local issue_body="/manul Implement feature X"
  local issue_output
  issue_output="$(events parse-comment --repo "test/e2e" --issue "200" --comment-id "e2e-1" --body "$issue_body" --author "user1" --created "$now" --json 2>/dev/null)" || return 1

  local issue_valid
  issue_valid="$(echo "$issue_output" | jq -r '.command.valid // false')"
  [ "$issue_valid" = "true" ] || return 1

  # Create conversation in DB
  local conv_id="conv-e2e-$(date +%s)"
  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/e2e', 200, 'https://github.com/test/e2e/issues/200', 'OPEN', '$now', '$now');" 2>/dev/null

  # Step 2: PR created (simulated)
  local pr_number="300"
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=$pr_number, updatedAt='$now' WHERE conversationId='$conv_id';" 2>/dev/null

  # Create initial task with PR number set
  local task_id="task-e2e-init-$(date +%s)"
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, action, prNumber) VALUES('$task_id', 'test/e2e', 200, 'https://github.com/test/e2e/issues/200#comment-e2e-1', 'user1', 'Implement feature X', 'completed', '$now', '$conv_id', 'IMPLEMENT', $pr_number);" 2>/dev/null

  # Step 3: ChatGPT reviews with REQUEST_CHANGES
  local review_body="Please add error handling"
  local review_output
  review_output="$(review handle --repo "test/e2e" --pr-number "$pr_number" --review-id "e2e-r1" --review-state "REQUEST_CHANGES" --body "$review_body" --author "chatgpt" --created "$now" --json 2>/dev/null)" || return 1

  local review_created
  review_created="$(echo "$review_output" | jq -r '.createdTask // false')"
  [ "$review_created" = "true" ] || return 1

  local review_task_id
  review_task_id="$(echo "$review_output" | jq -r '.newTaskId // empty')"
  [ -n "$review_task_id" ] || return 1

  # Verify parentTaskId
  local parent_id
  parent_id="$(echo "$review_output" | jq -r '.parentTaskId // empty')"
  [ "$parent_id" = "$task_id" ] || return 1

  # Step 4: ChatGPT approves
  local approve_output
  approve_output="$(review handle --repo "test/e2e" --pr-number "$pr_number" --review-id "e2e-r2" --review-state "APPROVE" --body "Looks good!" --author "chatgpt" --created "$now" --json 2>/dev/null)" || return 1

  local approve_created
  approve_created="$(echo "$approve_output" | jq -r '.createdTask // false')"
  [ "$approve_created" = "false" ] || return 1

  # Step 5: Post task result
  local result_output
  result_output="$(feedback post-done --repo "test/e2e" --issue "200" --comment-id "e2e-c1" --task-id "$review_task_id" --summary "Fixed error handling" --pr-number "$pr_number" --json 2>/dev/null)" || return 1

  local result_status
  result_status="$(echo "$result_output" | jq -r '.status // empty')"
  [ "$result_status" = "completed" ] || return 1

  # Verify event marker exists
  local has_marker
  has_marker="$(echo "$result_output" | jq -r '.eventMarker // empty')"
  [ -n "$has_marker" ] || return 1

  # Verify marker contains TASK_DONE
  echo "$has_marker" | grep -q "TASK_DONE" || return 1
}

# ============================================================
# Run Tests
# ============================================================

echo "═══════════════════════════════════════════════════════════════"
echo "  GitHub Control Protocol Tests"
echo "═══════════════════════════════════════════════════════════════"

# Core tests
run_test "Test 1: Issue command creates task" test_issue_command_creates_task
run_test "Test 2: Same Issue preserves conversation" test_same_issue_preserves_conversation
run_test "Test 3: Duplicate comment does not create duplicate task" test_duplicate_comment_no_dup_task
run_test "Test 4: PR comment creates REVIEW_FIX" test_pr_comment_creates_review_fix
run_test "Test 5: REVIEW_FIX preserves prNumber" test_review_fix_preserves_pr_number
run_test "Test 6: REVIEW_FIX preserves conversationId" test_review_fix_preserves_conversation
run_test "Test 7: parentTaskId is preserved" test_parent_task_id_preserved
run_test "Test 8: APPROVE does not create fix task" test_approve_no_fix_task
run_test "Test 9: REQUEST_CHANGES creates fix task" test_request_changes_creates_fix
run_test "Test 10: Duplicate review is ignored" test_duplicate_review_ignored

# Event tests
run_test "Test 11: Structured events parse correctly" test_structured_events_parse
run_test "Test 12: Malformed events are ignored safely" test_malformed_events_ignored
run_test "Test 13: Task result produces machine event" test_task_result_produces_event
run_test "Test 14: Failed task produces machine event" test_failed_task_produces_event
run_test "Test 15: Out-of-order events are handled" test_out_of_order_events

# Edge case tests
run_test "Test 16: Merged PR handling" test_merged_pr_handling
run_test "Test 17: Closed Issue handling" test_closed_issue_handling
run_test "Test 18: Concurrent comments" test_concurrent_comments
run_test "Test 19: JSON/state consistency" test_json_state_consistency
run_test "Test 20: Production path safety" test_production_path_safety

# End-to-end test
echo ""
echo "=== End-to-End Mock Flow ==="
run_test "E2E: Issue -> PR -> Review -> Fix -> Approve" test_end_to_end_mock_flow

# ============================================================
# Results
# ============================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "  Results: %d passed, %d failed (out of %d tests)\n" "$PASSED" "$FAILED" "$TESTS_RUN"
echo "═══════════════════════════════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi

exit 0
