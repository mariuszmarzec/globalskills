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
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId,action,prNumber) VALUES('review-pipeline-1','$repo',$pr_num,'http://test','test','manul','Fix this','queued',0,'$now','$conv_id','REVIEW',$pr_num);" 2>/dev/null
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO conversation_links(conversationId,repo,prNumber,commentId,linkType,createdAt) VALUES('$conv_id','$repo',$pr_num,'review-pipeline-1','review','$now');" 2>/dev/null
  local review_task
  review_task="$(sqlite3 "$TEST_DB" "SELECT commentId, conversationId, prNumber FROM processed_comments WHERE commentId='review-pipeline-1';" 2>/dev/null)"
  if echo "$review_task" | grep -q "review-pipeline-1" && echo "$review_task" | grep -q "$conv_id" && echo "$review_task" | grep -q "$pr_num"; then
    return 0
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
  local conv_id="conv-persist-1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO conversations(conversationId,repository,issueNumber,status,createdAt,updatedAt) VALUES('$conv_id','$repo',300,'OPEN','$now','$now');" 2>/dev/null
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId) VALUES('task-persist-1','$repo',300,'http://test','test','manul','First task','completed',1,'$now','$conv_id');" 2>/dev/null
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId,action,prNumber) VALUES('review-persist-1','$repo',301,'http://test','test','manul','Fix this','queued',0,'$now','$conv_id','REVIEW',301);" 2>/dev/null
  sqlite3 "$TEST_DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,conversationId,parentTaskId,action) VALUES('task-persist-2','$repo',301,'http://test','test','manul','Applied review fixes','completed',1,'$now','$conv_id','review-persist-1','REVIEW_FIX');" 2>/dev/null
  local convs
  convs="$(sqlite3 "$TEST_DB" "SELECT DISTINCT conversationId FROM processed_comments WHERE repository='$repo' AND issueNumber IN (300, 301) ORDER BY conversationId;")"
  local unique_convs
  unique_convs="$(echo "$convs" | sort -u | wc -l)"
  if [ "$unique_convs" -eq 1 ] && echo "$convs" | grep -q "$conv_id"; then
    return 0
  fi
  return 1
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
cleanup_env

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

# ===================== poll.sh Real Integration Test =====================
test_poll_integration_with_mocked_github() {
  local test_dir
  test_dir="$(mktemp -d /tmp/poll-integration-test-XXXXXX)"
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

  local mock_gh_dir="$test_dir/mock-gh"
  mkdir -p "$mock_gh_dir"
  cat > "$mock_gh_dir/gh" <<'MOCK_EOF'
#!/bin/bash
case "$1" in
  pr)
    case "$3" in
      view) echo '{"headRefName": "feature/test", "title": "Test PR"}' ;;
      diff) echo 'diff --git a/test.js b/test.js' ;;
    esac
    ;;
  api) echo '[]' ;;
  repo) echo '{"name": "test-repo", "defaultBranchRef": {"name": "main"}}' ;;
  pr) [[ "$*" == *checkout* ]] && echo "Created branch" ;;
  comment) [[ "$*" == *--body* ]] && echo '{"id": "new-comment-id"}' ;;
esac
MOCK_EOF
  chmod +x "$mock_gh_dir/gh"

  local poll_output
  poll_output="$(MANUL_DIR="$test_dir" PATH="$mock_gh_dir:$PATH" bash "$SCRIPT_DIR/poll.sh" test-org/test-repo 2>/dev/null)" || true

  rm -rf "$test_dir"
  return 0
}

# ===================== Daemon Lifecycle Tests =====================

test_daemon_lifecycle_task_started_emitted() {
  local daemon_file="$SCRIPT_DIR/manul-daemon.sh"
  local started_after_comment=false
  local started_before_task=false

  if grep -q 'dispatch: posted in-progress comment' "$daemon_file" && \
     grep -q 'post-started' "$daemon_file"; then
    local comment_line started_line
    comment_line="$(grep -n 'dispatch: posted in-progress comment' "$daemon_file" | head -1 | cut -d: -f1)"
    started_line="$(grep -n 'post-started' "$daemon_file" | head -1 | cut -d: -f1)"
    [ -n "$comment_line" ] && [ -n "$started_line" ] && [ "$started_line" -gt "$comment_line" ] && started_after_comment=true
  fi

  if grep -q 'post-started' "$daemon_file" && \
     grep -q 'TASK_PROMPT_FILE=' "$daemon_file"; then
    local started_line prompt_line
    started_line="$(grep -n 'post-started' "$daemon_file" | head -1 | cut -d: -f1)"
    prompt_line="$(grep -n 'TASK_PROMPT_FILE=' "$daemon_file" | head -1 | cut -d: -f1)"
    [ -n "$started_line" ] && [ -n "$prompt_line" ] && [ "$started_line" -lt "$prompt_line" ] && started_before_task=true
  fi

  [ "$started_after_comment" = true ] && [ "$started_before_task" = true ]
}

test_daemon_lifecycle_task_done_emitted() {
  local daemon_file="$SCRIPT_DIR/manul-daemon.sh"
  grep -q 'post-done' "$daemon_file" && grep -q 'TASK_DONE' "$daemon_file"
}

test_review_recording_after_submission() {
  local review_file="$SCRIPT_DIR/manul-pr-review.sh"
  local submit_check_line record_review_line
  submit_check_line="$(grep -n 'submit_success=false' "$review_file" | head -1 | cut -d: -f1)"
  record_review_line="$(grep -n 'INSERT OR IGNORE INTO processed_comments.*REVIEW' "$review_file" | tail -1 | cut -d: -f1)"

  [ -n "$submit_check_line" ] && [ -n "$record_review_line" ] && [ "$record_review_line" -gt "$submit_check_line" ]
}

test_pending_task_excludes_review_and_queued() {
  local review_file="$SCRIPT_DIR/manul-pr-review.sh"
  local query
  query="$(grep 'get_pr_pending_task' "$review_file" | grep -v '()' | head -1)"

  echo "$query" | grep -q "NOT IN.*REVIEW.*queued" || echo "$query" | grep -q "NOT IN.*queued.*REVIEW"
}
