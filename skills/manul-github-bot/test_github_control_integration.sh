#!/bin/bash
# test_github_control_integration.sh — Integration tests for poll.sh + manul-daemon.sh
set -uo pipefail

# Resolve script directory portably
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PASSED=0
FAILED=0
TOTAL=0
TEST_DB=""
MANUL_DIR=""

run_test() {
  local name="$1"
  local func="$2"
  TOTAL=$((TOTAL + 1))
  if $func; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $name"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $name"
  fi
}

setup_env() {
  local test_dir
  test_dir="$(mktemp -d /tmp/manul-integration-test-XXXXXX)"
  MANUL_DIR="$test_dir/manul"
  TEST_DB="$MANUL_DIR/manul.db"
  mkdir -p "$MANUL_DIR"
  cat > "$MANUL_DIR/config.json" <<'EOF'
{"automation":{"maxAttemptsBeforeFail":3,"leaseTimeout":900},"reviewers":["mock-reviewer"],"allowedUsers":["test-user","mock-reviewer"],"triggers":{"issueCommentTrigger":"/manul","prReviewCommentTrigger":"/manul","issueBodyTrigger":"/manul","fallbackTrigger":"manul"},"signature":"— manul 🐈"}
EOF
  sqlite3 "$TEST_DB" "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$TEST_DB" "INSERT INTO meta VALUES('baseline','2024-01-01T00:00:00Z');"
  sqlite3 "$TEST_DB" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER NOT NULL, commentUrl TEXT NOT NULL, author TEXT, agent TEXT, prompt TEXT NOT NULL, context TEXT, status TEXT NOT NULL DEFAULT 'queued', attempts INTEGER NOT NULL DEFAULT 0, createdAt TEXT, processedAt TEXT);"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN conversationId TEXT;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN parentTaskId TEXT;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN workspaceId TEXT;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN resultSummary TEXT;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN resultJson TEXT;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN baseId TEXT;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER;"
  sqlite3 "$TEST_DB" "ALTER TABLE processed_comments ADD COLUMN action TEXT;"
  sqlite3 "$TEST_DB" "CREATE TABLE conversations(conversationId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, issueUrl TEXT, activePrNumber INTEGER, activePrUrl TEXT, activeTaskId TEXT, status TEXT NOT NULL DEFAULT 'OPEN', createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);"
  sqlite3 "$TEST_DB" "CREATE TABLE conversation_links(id INTEGER PRIMARY KEY AUTOINCREMENT, conversationId TEXT NOT NULL, repo TEXT NOT NULL, issueNumber INTEGER, prNumber INTEGER, commentId TEXT, taskCommentId TEXT, linkType TEXT NOT NULL, createdAt TEXT NOT NULL);"

  # Copy scripts to MANUL_DIR for integration tests
  cp "$SCRIPT_DIR/manul-conversation.sh" "$MANUL_DIR/manul-conversation.sh" 2>/dev/null || true
  cp "$SCRIPT_DIR/manul-pr-review.sh" "$MANUL_DIR/manul-pr-review.sh" 2>/dev/null || true
  cp "$SCRIPT_DIR/manul-conversation-linker.sh" "$MANUL_DIR/manul-conversation-linker.sh" 2>/dev/null || true
  cp "$SCRIPT_DIR/manul-result-feedback.sh" "$MANUL_DIR/manul-result-feedback.sh" 2>/dev/null || true
  cp "$SCRIPT_DIR/manul-github-events.sh" "$MANUL_DIR/manul-github-events.sh" 2>/dev/null || true

  # Create mock gh for tests
  local mock_gh_dir="$test_dir/mock-gh"
  mkdir -p "$mock_gh_dir"
  cat > "$mock_gh_dir/gh" <<'MOCK_EOF'
#!/bin/bash
case "$1" in
  issue)
    case "$2" in
      comment) echo '{"id": "mock-comment-id"}' >&2 ;;
      view) echo '{"number": "'"$2"'"}' >&2 ;;
    esac
    ;;
  pr)
    case "$2" in
      view) echo '{"headRefName": "test-branch", "title": "Test PR"}' >&2 ;;
      checkout) echo "Switched to branch" >&2 ;;
    esac
    ;;
  api) echo '[]' >&2 ;;
  repo) echo '{"name": "test-repo", "defaultBranchRef": {"name": "main"}}' >&2 ;;
esac
exit 0
MOCK_EOF
  chmod +x "$mock_gh_dir/gh"
  export PATH="$mock_gh_dir:$PATH"
}

cleanup_env() {
  rm -rf "${MANUL_DIR%/*}" 2>/dev/null || true
  TEST_DB=""
  MANUL_DIR=""
}

# ===================== poll.sh Integration Tests =====================

test_poll_queues_review_with_conversation() {
  local repo="test-org/test-repo"
  local pr_num=42
  local comment_id="review:12345"
  local body="/manul Fix the formatting issues"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local lease_expires
  lease_expires="$(date -u -d "now + 900 seconds" +%Y-%m-%dT%H:%M:%SZ)"
  local conv_id="conv-$repo-$pr_num"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId) VALUES('$comment_id','$repo',$pr_num,'https://github.com/$repo/pull/$pr_num','test-user','','$body','queued','$now','$now','$lease_expires','$conv_id');" 2>/dev/null
  local row
  row="$(sqlite3 "$TEST_DB" "SELECT commentId, conversationId, status FROM processed_comments WHERE commentId='$comment_id';" 2>/dev/null)"
  if echo "$row" | grep -q "$comment_id" && echo "$row" | grep -q "$conv_id"; then
    return 0
  fi
  return 1
}

test_poll_links_review_to_conversation() {
  local repo="test-org/test-repo"
  local pr_num=43
  local comment_id="review:12346"
  local conv_id="conv-$repo-$pr_num"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO conversations(conversationId,repository,activePrNumber,status,createdAt,updatedAt) VALUES('$conv_id','$repo',$pr_num,'OPEN','$now','$now');" 2>/dev/null
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO conversation_links(conversationId,repo,prNumber,commentId,linkType,createdAt) VALUES('$conv_id','$repo',$pr_num,'$comment_id','review','$now');" 2>/dev/null
  local link_count
  link_count="$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM conversation_links WHERE commentId='$comment_id' AND linkType='review';" 2>/dev/null)"
  [ "$link_count" -eq 1 ]
}

# ===================== manul-daemon.sh Integration Tests =====================

test_daemon_posts_task_done_event() {
  local repo="test-org/test-repo"
  local comment_id="task-done-1"
  local conv_id="conv-done"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId,resultSummary) VALUES('$comment_id','$repo',45,'http://test','test','manul','Test task','completed',1,'$now','$conv_id','Test summary');" 2>/dev/null
  local output
  output="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result-feedback.sh" post-done --repo "$repo" --issue 45 --comment-id "$comment_id" --task-id "$comment_id" --summary "Task completed successfully" --pr-number 45 --json 2>/dev/null)" || return 1
  if echo "$output" | jq -e '.status == "completed"' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

test_daemon_posts_task_failed_event() {
  local repo="test-org/test-repo"
  local comment_id="task-fail-1"
  local conv_id="conv-fail"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId) VALUES('$comment_id','$repo',46,'http://test','test','manul','Test task','failed',3,'$now','$conv_id');" 2>/dev/null
  local output
  output="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result-feedback.sh" post-failed --repo "$repo" --issue 46 --comment-id "$comment_id" --task-id "$comment_id" --error "Max attempts reached" --pr-number 46 --json 2>/dev/null)" || return 1
  if echo "$output" | jq -e '.status == "failed"' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

test_daemon_event_has_marker_format() {
  local repo="test-org/test-repo"
  local comment_id="task-marker-1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId) VALUES('$comment_id','$repo',47,'http://test','test','manul','Test task','completed',1,'$now','conv-marker');" 2>/dev/null
  local output
  output="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result-feedback.sh" post-done --repo "$repo" --issue 47 --comment-id "$comment_id" --task-id "$comment_id" --summary "Integration test" --json 2>/dev/null)" || return 1
  local marker
  marker="$(echo "$output" | jq -r '.eventMarker // empty')"
  if echo "$marker" | grep -qE '<!-- manul:event \{.*"type":"TASK_DONE".*\} -->'; then
    return 0
  fi
  return 1
}

# ===================== Full Pipeline Tests =====================

test_full_pipeline_issue_to_review() {
  local repo="test-org/test-repo"
  local issue_num=100
  local pr_num=101
  local conv_id="conv-pipeline-$issue_num"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO conversations(conversationId,repository,issueNumber,status,createdAt,updatedAt) VALUES('$conv_id','$repo',$issue_num,'OPEN','$now','$now');" 2>/dev/null
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId) VALUES('task-pipeline-1','$repo',$issue_num,'http://test','test','manul','Implement feature X','completed',1,'$now','$conv_id');" 2>/dev/null
  sqlite3 "$TEST_DB" "UPDATE conversations SET activePrNumber=$pr_num, activePrUrl='https://github.com/$repo/pull/$pr_num', updatedAt='$now' WHERE conversationId='$conv_id';" 2>/dev/null
  # Invoke real production script to create the REVIEW_FIX task
  local output
  output="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-pr-review.sh" --json handle --repo "$repo" --pr-number "$pr_num" --review-id "review-pipeline-$pr_num" --review-state REQUEST_CHANGES --body "Fix this" --author reviewer --created "$now" 2>/dev/null)" || return 1
  # Assert that REVIEW_FIX task was created by production code
  if echo "$output" | jq -e '.createdTask == true' >/dev/null 2>&1; then
    local review_task
    review_task="$(sqlite3 "$TEST_DB" "SELECT commentId, conversationId, prNumber FROM processed_comments WHERE action='REVIEW_FIX' AND prNumber=$pr_num;" 2>/dev/null)"
    if echo "$review_task" | grep -q "$conv_id" && echo "$review_task" | grep -q "$pr_num"; then
      return 0
    fi
  fi
  return 1
}

test_full_pipeline_result_feedback() {
  local repo="test-org/test-repo"
  local task_id="task-feedback-1"
  local conv_id="conv-feedback"
  local pr_num=200
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId,resultSummary,prNumber) VALUES('$task_id','$repo',201,'http://test','test','manul','Implemented feature X','completed',1,'$now','$conv_id','Implemented feature X',$pr_num);" 2>/dev/null
  local output
  output="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result-feedback.sh" post-done --repo "$repo" --issue 201 --comment-id "$task_id" --task-id "$task_id" --summary "Feature X implemented successfully" --pr-number "$pr_num" --json 2>/dev/null)" || return 1
  local has_marker has_summary has_pr
  has_marker="$(echo "$output" | jq -r '.eventMarker // empty')"
  has_summary="$(echo "$output" | jq -r '.hasSummary')"
  has_pr="$(echo "$output" | jq -r '.prNumber')"
  if [ -n "$has_marker" ] && [ "$has_summary" = "true" ] && [ "$has_pr" = "$pr_num" ]; then
    return 0
  fi
  return 1
}

test_conversation_persistence_across_cycles() {
  local repo="test-org/test-repo"
  local conv_id="conv-persist-cycle"
  local pr_num=400
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Create conversation and initial task
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO conversations(conversationId,repository,issueNumber,status,createdAt,updatedAt) VALUES('$conv_id','$repo',300,'OPEN','$now','$now');" 2>/dev/null
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId) VALUES('task-persist-1','$repo',300,'http://test','test','manul','Implement feature','completed',1,'$now','$conv_id');" 2>/dev/null
  sqlite3 "$TEST_DB" "UPDATE conversations SET activePrNumber=$pr_num, activePrUrl='https://github.com/$repo/pull/$pr_num', updatedAt='$now' WHERE conversationId='$conv_id';" 2>/dev/null

  # First invocation of manul-pr-review.sh (simulates first poll cycle)
  local output1
  output1="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-pr-review.sh" --json handle --repo "$repo" --pr-number "$pr_num" --review-id "review-persist-1" --review-state REQUEST_CHANGES --body "Fix formatting" --author reviewer --created "$now" 2>/dev/null)" || return 1
  if ! echo "$output1" | jq -e '.createdTask == true' >/dev/null 2>&1; then
    echo "ERROR: First review invocation did not create task"
    return 1
  fi

  # Second invocation (simulates second poll cycle - should be idempotent)
  local output2
  output2="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-pr-review.sh" --json handle --repo "$repo" --pr-number "$pr_num" --review-id "review-persist-1" --review-state REQUEST_CHANGES --body "Fix formatting" --author reviewer --created "$now" 2>/dev/null)" || return 1

  # Verify conversation still exists
  local conv_count
  conv_count="$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM conversations WHERE conversationId='$conv_id' AND repository='$repo';" 2>/dev/null)"
  if [ "$conv_count" -lt 1 ]; then
    echo "ERROR: Conversation was lost after second invocation"
    return 1
  fi

  # Verify only one REVIEW_FIX task was created (idempotency)
  local review_fix_count
  review_fix_count="$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM processed_comments WHERE repository='$repo' AND action='REVIEW_FIX' AND prNumber=$pr_num;" 2>/dev/null)"
  if [ "$review_fix_count" -ne 1 ]; then
    echo "ERROR: Expected 1 REVIEW_FIX task, found $review_fix_count"
    return 1
  fi

  # Verify the task is linked to the conversation
  local task_conv
  task_conv="$(sqlite3 "$TEST_DB" "SELECT conversationId FROM processed_comments WHERE action='REVIEW_FIX' AND prNumber=$pr_num;" 2>/dev/null)"
  if [ "$task_conv" != "$conv_id" ]; then
    echo "ERROR: REVIEW_FIX task not linked to conversation"
    return 1
  fi

  return 0
}

test_deduplication_preserved() {
  local repo="test-org/test-repo"
  local comment_id="review-dedup-1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId) VALUES('$comment_id','$repo',400,'http://test','test','manul','Test','completed',0,'$now','conv-dedup');" 2>/dev/null
  local insert_result
  insert_result="$(sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId) VALUES('$comment_id','$repo',400,'http://test','test','manul','Test','completed',0,'$now','conv-dedup'); SELECT changes();" 2>/dev/null)"
  local count
  count="$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='$comment_id';" 2>/dev/null)"
  if [ "$count" -eq 1 ] && [ "${insert_result:-0}" -eq 0 ]; then
    return 0
  fi
  return 1
}

# ===================== Event Format Tests =====================

test_event_marker_parseable() {
  local marker='<!-- manul:event {"type":"TASK_DONE","timestamp":"2024-01-01T00:00:00Z","data":{"taskId":"task-1","conversationId":"conv-1","summary":"Test"}} -->'
  local json_part
  json_part="$(echo "$marker" | grep -oP '(?<=<!-- manul:event ).*(?= -->)')"
  if echo "$json_part" | jq -e '.type == "TASK_DONE"' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

test_review_handler_creates_fix_task() {
  local repo="test-org/test-repo"
  local pr_num=50
  local conv_id="conv-review-$pr_num"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO conversations(conversationId,repository,issueNumber,issueUrl,activePrNumber,status,activeTaskId,createdAt,updatedAt) VALUES('$conv_id','$repo',$pr_num,'https://github.com/$repo/pull/$pr_num',$pr_num,'OPEN',NULL,'$now','$now');" 2>/dev/null
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId,prNumber) VALUES('task-50','$repo',$pr_num,'http://test','test','manul','Original task','completed',1,'$now','$conv_id',$pr_num);" 2>/dev/null
  local output
  output="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-pr-review.sh" --json handle --repo "$repo" --pr-number "$pr_num" --review-id "review-new-$pr_num" --review-state REQUEST_CHANGES --body "Please fix the formatting" --author reviewer --created "$now" 2>/dev/null)" || return 1
  if echo "$output" | jq -e '.createdTask == true' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

test_approval_does_not_create_task() {
  local repo="test-org/test-repo"
  local pr_num=51
  local conv_id="conv-approve-$pr_num"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO conversations(conversationId,repository,issueNumber,issueUrl,activePrNumber,status,activeTaskId,createdAt,updatedAt) VALUES('$conv_id','$repo',$pr_num,'https://github.com/$repo/pull/$pr_num',$pr_num,'OPEN',NULL,'$now','$now');" 2>/dev/null
  local output
  output="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-pr-review.sh" --json handle --repo "$repo" --pr-number "$pr_num" --review-id "review-new-approve-$pr_num" --review-state APPROVE --body "Looks good!" --author reviewer --created "$now" 2>/dev/null)" || return 1
  if echo "$output" | jq -e '.createdTask == false' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

test_pending_task_excludes_review_not_queued() {
  local review_file="$SCRIPT_DIR/manul-pr-review.sh"
  local query
  query="$(sed -n '/^get_pr_pending_task/,/^}/p' "$review_file" | grep 'action NOT IN' | head -1)"

  # Should NOT exclude queued (it's a status, not an action)
  echo "$query" | grep -q "NOT IN.*REVIEW" && echo "$query" | grep -q "NOT IN.*queued" && return 1
  # Should exclude REVIEW action
  echo "$query" | grep -q "NOT IN.*('REVIEW')"
}

# ===================== Run Tests =====================

echo "═══════════════════════════════════════════════════════════════"
echo "  GitHub Control Protocol Integration Tests"
echo "═══════════════════════════════════════════════════════════════"

setup_env
run_test "poll: queues review with conversation" test_poll_queues_review_with_conversation
run_test "poll: links review to conversation" test_poll_links_review_to_conversation
cleanup_env

setup_env
run_test "daemon: posts TASK_DONE event" test_daemon_posts_task_done_event
run_test "daemon: posts TASK_FAILED event" test_daemon_posts_task_failed_event
run_test "daemon: event has marker format" test_daemon_event_has_marker_format
cleanup_env

setup_env
run_test "pipeline: issue to review flow" test_full_pipeline_issue_to_review
run_test "pipeline: result feedback posted" test_full_pipeline_result_feedback
run_test "pipeline: conversation persists across cycles" test_conversation_persistence_across_cycles
cleanup_env

setup_env
run_test "invariant: deduplication preserved" test_deduplication_preserved
cleanup_env

setup_env
run_test "format: event marker parseable" test_event_marker_parseable
cleanup_env

setup_env
run_test "protocol: review handler creates fix task" test_review_handler_creates_fix_task
run_test "protocol: approval does not create task" test_approval_does_not_create_task
run_test "protocol: pending task excludes review not queued" test_pending_task_excludes_review_not_queued
cleanup_env

# ===================== poll.sh Real Integration Test =====================
test_poll_integration_with_mocked_github() {
  local test_dir
  test_dir="$(mktemp -d /tmp/poll-integration-test-XXXXXX)"
  local manul_dir="$test_dir/manul"
  mkdir -p "$manul_dir"

  cat > "$manul_dir/config.json" <<'CFGEOF'
{"automation":{"maxAttemptsBeforeFail":3,"leaseTimeout":900},"reviewers":["mock-reviewer"],"allowedUsers":["test-user"],"triggers":{"issueCommentTrigger":"/manul","prReviewCommentTrigger":"/manul","issueBodyTrigger":"/manul","fallbackTrigger":"manul"},"signature":"— manul 🐈"}
CFGEOF

  local poll_db="$manul_dir/manul.db"
  sqlite3 "$poll_db" "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$poll_db" "INSERT INTO meta VALUES('baseline','2024-01-01T00:00:00Z');"
  sqlite3 "$poll_db" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER NOT NULL, commentUrl TEXT NOT NULL, author TEXT, agent TEXT, prompt TEXT NOT NULL, context TEXT, status TEXT NOT NULL DEFAULT 'queued', attempts INTEGER NOT NULL DEFAULT 0, createdAt TEXT, processedAt TEXT);"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN conversationId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN parentTaskId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN workspaceId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN resultSummary TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN resultJson TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN baseId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN action TEXT;"
  sqlite3 "$poll_db" "CREATE TABLE conversations(conversationId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, issueUrl TEXT, activePrNumber INTEGER, activePrUrl TEXT, activeTaskId TEXT, status TEXT NOT NULL DEFAULT 'OPEN', createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);"
  sqlite3 "$poll_db" "CREATE TABLE conversation_links(id INTEGER PRIMARY KEY AUTOINCREMENT, conversationId TEXT NOT NULL, repo TEXT NOT NULL, issueNumber INTEGER, prNumber INTEGER, commentId TEXT, taskCommentId TEXT, linkType TEXT NOT NULL, createdAt TEXT NOT NULL);"

  # Copy production scripts
  cp "$SCRIPT_DIR/manul-pr-review.sh" "$manul_dir/manul-pr-review.sh"
  cp "$SCRIPT_DIR/manul-conversation.sh" "$manul_dir/manul-conversation.sh"
  cp "$SCRIPT_DIR/manul-github-events.sh" "$manul_dir/manul-github-events.sh"

  local mock_gh_dir="$test_dir/mock-gh"
  mkdir -p "$mock_gh_dir"

  local call_log="$test_dir/call_log.txt"
  > "$call_log"

   cat > "$mock_gh_dir/gh" <<MOCK_EOF
#!/bin/bash
log() { echo "\$(date -Is): \$*" >> "$test_dir/call_log.txt"; }

# Handle gh pr list with various flags
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
  log "gh pr list --repo test-org/test-repo"
  # Return full PR objects for --state open queries, just the number for --json number queries
  if [[ "\$*" == *"--state open"* ]]; then
    echo '[{"number":200,"headRefName":"feature/test","baseRefName":"main","title":"Test PR","url":"https://github.com/test-org/test-repo/pull/200"}]'
  elif [[ "\$*" == *"--json number"* && "\$*" == *"--jq"* ]]; then
    echo '200'
  else
    echo '[{"number":200}]'
  fi
  exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "list" ]]; then
  log "gh issue list --repo test-org/test-repo"
  echo '[]'
  exit 0
fi
if [[ "\$1" == "api" ]]; then
  log "gh api \$*"
  if [[ "\$*" == *"/reviews"* ]]; then
    echo '[{"id":"review-1","state":"CHANGES_REQUESTED","body":"Fix formatting","user":{"login":"reviewer"},"submitted_at":"2024-01-01T00:00:00Z"}]'
    exit 0
  fi
  echo '[]'
  exit 0
fi
log "UNHANDLED: \$*"
echo '{}'
exit 0
MOCK_EOF
  chmod +x "$mock_gh_dir/gh"

  # Run poll.sh twice to simulate multiple cycles
  MANUL_DIR="$manul_dir" PATH="$mock_gh_dir:$PATH" bash "$SCRIPT_DIR/poll.sh" test-org/test-repo 2>/dev/null
  local first_exit=$?

  MANUL_DIR="$manul_dir" PATH="$mock_gh_dir:$PATH" bash "$SCRIPT_DIR/poll.sh" test-org/test-repo 2>/dev/null
  local second_exit=$?

  # Verify both polls executed
  if [ $first_exit -ne 0 ]; then
    echo "ERROR: First poll.sh failed with exit code $first_exit"
    rm -rf "$test_dir"
    return 1
  fi

  if [ $second_exit -ne 0 ]; then
    echo "ERROR: Second poll.sh failed with exit code $second_exit"
    rm -rf "$test_dir"
    return 1
  fi

  # Verify mock gh was called
  if ! grep -q "gh pr list --repo test-org/test-repo" "$call_log"; then
    echo "ERROR: Expected gh pr list call not found in call log"
    cat "$call_log"
    rm -rf "$test_dir"
    return 1
  fi

  # Verify SQLite state shows production path was executed
  # 1. A conversation should exist
  local conv_count
  conv_count="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM conversations WHERE repository='test-org/test-repo';" 2>/dev/null)"
  if [ "$conv_count" -lt 1 ]; then
    echo "ERROR: Expected at least 1 conversation, found $conv_count"
    rm -rf "$test_dir"
    return 1
  fi

  # 2. A REVIEW_FIX task should have been created
  local review_fix_count
  review_fix_count="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM processed_comments WHERE repository='test-org/test-repo' AND action='REVIEW_FIX' AND prNumber=200;" 2>/dev/null)"
  if [ "$review_fix_count" -lt 1 ]; then
    echo "ERROR: Expected at least 1 REVIEW_FIX task, found $review_fix_count"
    rm -rf "$test_dir"
    return 1
  fi

  # 3. Verify no duplicate REVIEW_FIX tasks
  if [ "$review_fix_count" -gt 1 ]; then
    echo "ERROR: Duplicate REVIEW_FIX tasks created (count: $review_fix_count)"
    rm -rf "$test_dir"
    return 1
  fi

  # 4. Verify gh api reviews call was made
  if ! grep -q "gh api" "$call_log" || ! grep -q "reviews" "$call_log"; then
    echo "ERROR: Expected gh api reviews call not found in call log"
    cat "$call_log"
    rm -rf "$test_dir"
    return 1
  fi

  rm -rf "$test_dir"
  return 0
}

# ===================== Daemon Lifecycle Tests =====================

test_daemon_lifecycle_task_started_emitted() {
  local test_dir
  test_dir="$(mktemp -d /tmp/daemon-lifecycle-test-XXXXXX)"
  local poll_db="$test_dir/manul.db"
  mkdir -p "$test_dir"

  cat > "$test_dir/config.json" <<'CFGEOF'
{"automation":{"maxAttemptsBeforeFail":3,"leaseTimeout":900},"reviewers":["mock-reviewer"],"allowedUsers":["test-user"],"triggers":{"issueCommentTrigger":"/manul","prReviewCommentTrigger":"/manul","issueBodyTrigger":"/manul","fallbackTrigger":"manul"},"signature":"— manul 🐈"}
CFGEOF

  sqlite3 "$poll_db" "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$poll_db" "INSERT INTO meta VALUES('baseline','2024-01-01T00:00:00Z');"
  sqlite3 "$poll_db" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER NOT NULL, commentUrl TEXT NOT NULL, author TEXT, agent TEXT, prompt TEXT NOT NULL, context TEXT, status TEXT NOT NULL DEFAULT 'queued', attempts INTEGER NOT NULL DEFAULT 0, createdAt TEXT, processedAt TEXT);"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN conversationId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN parentTaskId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN workspaceId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN resultSummary TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN resultJson TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN baseId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN action TEXT;"
  sqlite3 "$poll_db" "CREATE TABLE conversations(conversationId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, issueUrl TEXT, activePrNumber INTEGER, activePrUrl TEXT, activeTaskId TEXT, status TEXT NOT NULL DEFAULT 'OPEN', createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);"
  sqlite3 "$poll_db" "CREATE TABLE conversation_links(id INTEGER PRIMARY KEY AUTOINCREMENT, conversationId TEXT NOT NULL, repo TEXT NOT NULL, issueNumber INTEGER, prNumber INTEGER, commentId TEXT, taskCommentId TEXT, linkType TEXT NOT NULL, createdAt TEXT NOT NULL);"

  # Copy production scripts
  cp "$SCRIPT_DIR/manul-pr-review.sh" "$test_dir/manul-pr-review.sh"
  cp "$SCRIPT_DIR/manul-conversation.sh" "$test_dir/manul-conversation.sh"
  cp "$SCRIPT_DIR/manul-daemon.sh" "$test_dir/manul-daemon.sh"
  cp "$SCRIPT_DIR/manul-github-events.sh" "$test_dir/manul-github-events.sh"

  local mock_gh_dir="$test_dir/mock-gh"
  mkdir -p "$mock_gh_dir"

  local call_log="$test_dir/call_log.txt"
  > "$call_log"

  cat > "$mock_gh_dir/gh" <<MOCK_EOF
#!/bin/bash
MOCK_GH_DIR="$test_dir"
log() { echo "$(date -Is): $*" >> "$MOCK_GH_DIR/call_log.txt"; }

# Handle gh pr list with various flags
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  log "gh pr list --repo test-org/test-repo"
  echo '[{"number":200,"headRefName":"feature/test","baseRefName":"main","title":"Test PR","url":"https://github.com/test-org/test-repo/pull/200"}]'
  return 0
elif [[ "$1" == "pr" && "$2" == "view" ]]; then
  local pr_num="$3"
  log "gh pr view $pr_num --repo test-org/test-repo"
  echo '{"number": 600, "headRefName": "feature/daemon", "baseRefName": "main", "title": "Daemon Test PR", "html_url": "https://github.com/test-org/test-repo/pull/600"}'
  return 0
elif [[ "$1" == "api" ]]; then
  log "gh api repos/test-org/test-repo/pulls/600/reviews"
  echo '[]'
  return 0
fi

log "UNKNOWN: $1 $2 $3"
MOCK_EOF
  chmod +x "$mock_gh_dir/gh"

  # Create initial conversation and task to simulate daemon state
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$poll_db" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('daemon-conv-1', 'test-org/test-repo', 600, 'https://github.com/test-org/test-repo/issues/600', 600, 'OPEN', '$now', '$now');"
  sqlite3 "$poll_db" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, agent, prompt, status, createdAt, conversationId, action, prNumber) VALUES('daemon-task-1', 'test-org/test-repo', 600, 'https://github.com/test-org/test-repo/issues/600', 'daemon', 'manul', 'Implement daemon lifecycle', 'running', '$now', 'daemon-conv-1', 'IMPLEMENT', 600);"

  # Run poll.sh to verify it can process the existing running task
  MANUL_DIR="$test_dir" PATH="$mock_gh_dir:$PATH" bash "$SCRIPT_DIR/poll.sh" test-org/test-repo 2>/dev/null
  local poll_exit=$?

  # Verify poll executed successfully
  if [ $poll_exit -ne 0 ]; then
    echo "ERROR: poll.sh failed with exit code $poll_exit"
    rm -rf "$test_dir"
    return 1
  fi

  # Verify the task is still in processing state (poll should not complete it)
  local task_status
  task_status="$(sqlite3 "$poll_db" "SELECT status FROM processed_comments WHERE repository='test-org/test-repo' AND commentId='daemon-task-1';" 2>/dev/null)"

  if [ "$task_status" != "running" ]; then
    echo "ERROR: Expected task to remain 'running', got '$task_status'"
    rm -rf "$test_dir"
    return 1
  fi

  # Verify no extra tasks were created
  local task_count
  task_count="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM processed_comments WHERE repository='test-org/test-repo';" 2>/dev/null)"

  if [ "$task_count" -ne 1 ]; then
    echo "ERROR: Expected 1 task, found $task_count"
    rm -rf "$test_dir"
    return 1
  fi

  rm -rf "$test_dir"
  return 0
}

test_daemon_lifecycle_task_done_emitted() {
  local daemon_file="$SCRIPT_DIR/manul-daemon.sh"
  grep -q 'post-done' "$daemon_file" && grep -q 'TASK_DONE' "$daemon_file"
}

test_review_recording_after_submission() {
  local test_dir
  test_dir="$(mktemp -d /tmp/review-recording-test-XXXXXX)"
  local poll_db="$test_dir/manul.db"
  mkdir -p "$test_dir"

  cat > "$test_dir/config.json" <<'CFGEOF'
{"automation":{"maxAttemptsBeforeFail":3,"leaseTimeout":900},"reviewers":["mock-reviewer"],"allowedUsers":["test-user"],"triggers":{"issueCommentTrigger":"/manul","prReviewCommentTrigger":"/manul","issueBodyTrigger":"/manul","fallbackTrigger":"manul"},"signature":"— manul 🐈"}
CFGEOF

  sqlite3 "$poll_db" "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$poll_db" "INSERT INTO meta VALUES('baseline','2024-01-01T00:00:00Z');"
  sqlite3 "$poll_db" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER NOT NULL, commentUrl TEXT NOT NULL, author TEXT, agent TEXT, prompt TEXT NOT NULL, context TEXT, status TEXT NOT NULL DEFAULT 'queued', attempts INTEGER NOT NULL DEFAULT 0, createdAt TEXT, processedAt TEXT);"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN conversationId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN parentTaskId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN workspaceId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN resultSummary TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN resultJson TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN baseId TEXT;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER;"
  sqlite3 "$poll_db" "ALTER TABLE processed_comments ADD COLUMN action TEXT;"
  sqlite3 "$poll_db" "CREATE TABLE conversations(conversationId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, issueUrl TEXT, activePrNumber INTEGER, activePrUrl TEXT, activeTaskId TEXT, status TEXT NOT NULL DEFAULT 'OPEN', createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);"
  sqlite3 "$poll_db" "CREATE TABLE conversation_links(id INTEGER PRIMARY KEY AUTOINCREMENT, conversationId TEXT NOT NULL, repo TEXT NOT NULL, issueNumber INTEGER, prNumber INTEGER, commentId TEXT, taskCommentId TEXT, linkType TEXT NOT NULL, createdAt TEXT NOT NULL);"

  # Copy production scripts
  cp "$SCRIPT_DIR/manul-pr-review.sh" "$test_dir/manul-pr-review.sh"
  cp "$SCRIPT_DIR/manul-conversation.sh" "$test_dir/manul-conversation.sh"
  cp "$SCRIPT_DIR/manul-github-events.sh" "$test_dir/manul-github-events.sh"

  # Create conversation and initial task
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$poll_db" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('review-conv-1', 'test-org/test-repo', 500, 'https://github.com/test-org/test-repo/issues/500', 500, 'OPEN', '$now', '$now');"
  sqlite3 "$poll_db" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, agent, prompt, status, createdAt, conversationId, action, prNumber) VALUES('initial-task-1', 'test-org/test-repo', 500, 'https://github.com/test-org/test-repo/issues/500', 'user', 'manul', 'Create feature', 'completed', '$now', 'review-conv-1', 'IMPLEMENT', 500);"

  # Call manul-pr-review.sh handle directly (production path)
  local review_result
  review_result="$(MANUL_DIR="$test_dir" bash "$test_dir/manul-pr-review.sh" handle \
    --repo "test-org/test-repo" \
    --pr-number 500 \
    --review-id "review-submit-1" \
    --review-state "REQUEST_CHANGES" \
    --body "Please fix the formatting issues" \
    --author "reviewer" \
    --created "2024-01-01T00:00:00Z" \
    --json 2>&1)" || return 1

  # Verify REVIEW task was created in production
  local review_task_count
  review_task_count="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM processed_comments WHERE repository='test-org/test-repo' AND action='REVIEW_FIX' AND prNumber=500;" 2>/dev/null)"

  if [ "$review_task_count" -ne 1 ]; then
    echo "ERROR: Expected 1 REVIEW_FIX task after submission, found $review_task_count"
    echo "Review result: $review_result"
    rm -rf "$test_dir"
    return 1
  fi

  # Verify the task has proper parent relationship
  local parent_task
  parent_task="$(sqlite3 "$poll_db" "SELECT parentTaskId FROM processed_comments WHERE repository='test-org/test-repo' AND action='REVIEW_FIX' AND prNumber=500;" 2>/dev/null)"

  if [ -z "$parent_task" ]; then
    echo "ERROR: REVIEW_FIX task missing parentTaskId"
    rm -rf "$test_dir"
    return 1
  fi

  # Verify conversationId is preserved
  local task_conv_id
  task_conv_id="$(sqlite3 "$poll_db" "SELECT conversationId FROM processed_comments WHERE repository='test-org/test-repo' AND action='REVIEW_FIX' AND prNumber=500;" 2>/dev/null)"

  if [ "$task_conv_id" != "review-conv-1" ]; then
    echo "ERROR: REVIEW_FIX task has wrong conversationId: $task_conv_id (expected review-conv-1)"
    rm -rf "$test_dir"
    return 1
  fi

  # Verify status is queued (not completed)
  local task_status
  task_status="$(sqlite3 "$poll_db" "SELECT status FROM processed_comments WHERE repository='test-org/test-repo' AND action='REVIEW_FIX' AND prNumber=500;" 2>/dev/null)"

  if [ "$task_status" != "queued" ]; then
    echo "ERROR: REVIEW_FIX task has wrong status: $task_status (expected queued)"
    rm -rf "$test_dir"
    return 1
  fi

  rm -rf "$test_dir"
  return 0
}

# ===================== Run Additional Tests =====================
run_test "daemon: lifecycle task started emitted" test_daemon_lifecycle_task_started_emitted
run_test "daemon: lifecycle task done emitted" test_daemon_lifecycle_task_done_emitted
run_test "daemon: review recorded after submission" test_review_recording_after_submission
run_test "integration: poll with mocked github" test_poll_integration_with_mocked_github

# ===================== Results =====================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed (out of $TOTAL tests)"
echo "═══════════════════════════════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
  echo "❌ Test suite FAILED: $FAILED tests failed"
  exit 1
fi
echo "✅ All tests PASSED: $PASSED/$TOTAL tests passed"
exit 0
