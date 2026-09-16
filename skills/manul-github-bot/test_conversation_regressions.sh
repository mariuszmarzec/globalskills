#!/bin/bash
# test_conversation_regressions.sh — Regression tests for PR #19
# Covers: issue conversation identity, idempotent persistence,
#         review-thread identity independent of comment count,
#         and full review-thread message persistence.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PASSED=0
FAILED=0
TOTAL=0

run_test() {
  local name="$1"
  local func="$2"
  TOTAL=$((TOTAL + 1))
  if "$func"; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $name"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $name"
  fi
}

# =============================================================================
# Test 1: Issue conversation — trigger → ordinary → follow-up trigger
# =============================================================================
test_issue_conversation_regression() {
  local test_dir
  test_dir="$(mktemp -d /tmp/conv-regression-issue-XXXXXX)"
  local manul_dir="$test_dir/manul"
  mkdir -p "$manul_dir"

  cat > "$manul_dir/config.json" <<'CFGEOF'
{"automation":{"maxAttemptsBeforeFail":3,"leaseTimeout":900},"reviewers":["mock-reviewer"],"allowedUsers":["test-user","reviewer","author"],"triggers":{"issueCommentTrigger":"/manul","prReviewCommentTrigger":"/manul","issueBodyTrigger":"/manul","fallbackTrigger":"manul"},"signature":"— manul 🐈"}
CFGEOF

  local poll_db="$manul_dir/manul.db"
  sqlite3 "$poll_db" "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$poll_db" "INSERT INTO meta VALUES('baseline','2019-01-01T00:00:00Z');"
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
  sqlite3 "$poll_db" "CREATE TABLE conversation_messages(messageId TEXT PRIMARY KEY, conversationId TEXT NOT NULL, commentId TEXT, repo TEXT, issueNumber INTEGER, author TEXT, body TEXT, commentUrl TEXT, createdAt TEXT, messageType TEXT);"

  cp "$SCRIPT_DIR/manul-pr-review.sh" "$manul_dir/manul-pr-review.sh"
  cp "$SCRIPT_DIR/manul-conversation.sh" "$manul_dir/manul-conversation.sh"
  cp "$SCRIPT_DIR/manul-github-events.sh" "$manul_dir/manul-github-events.sh"

  local mock_gh_dir="$test_dir/mock-gh"
  mkdir -p "$mock_gh_dir"

  # Each poll returns an increasingly complete comment set.
  # Poll 1: trigger-comment only
  # Poll 2: + ordinary-comment
  # Poll 3: + trigger-comment-2 (follow-up)
  # Poll 4 (idempotency): same as poll 3 — no new rows should be added
  cat > "$test_dir/comments_1.json" <<'EOF'
[{"id":"trigger-comment","body":"/manul Add a test for multiply(2, 3) == 6","user":{"login":"test-user"},"created_at":"2026-09-16T00:00:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#issuecomment-trigger","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"}]
EOF
  cat > "$test_dir/comments_2.json" <<'EOF'
[{"id":"trigger-comment","body":"/manul Add a test for multiply(2, 3) == 6","user":{"login":"test-user"},"created_at":"2026-09-16T00:00:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#issuecomment-trigger","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"},{"id":"ordinary-comment","body":"Also make sure the assertion uses float comparison.","user":{"login":"test-user"},"created_at":"2026-09-16T00:05:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#issuecomment-ordinary","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"}]
EOF
  cat > "$test_dir/comments_3.json" <<'EOF'
[{"id":"trigger-comment","body":"/manul Add a test for multiply(2, 3) == 6","user":{"login":"test-user"},"created_at":"2026-09-16T00:00:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#issuecomment-trigger","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"},{"id":"ordinary-comment","body":"Also make sure the assertion uses float comparison.","user":{"login":"test-user"},"created_at":"2026-09-16T00:05:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#issuecomment-ordinary","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"},{"id":"trigger-comment-2","body":"/manul Now implement the change according to my previous feedback.","user":{"login":"test-user"},"created_at":"2026-09-16T00:10:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#issuecomment-trigger-2","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"}]
EOF

  cat > "$mock_gh_dir/gh" <<'MOCK_EOF'
#!/bin/bash
set -u
if [[ "$1" == "pr" && "$2" == "list" ]]; then
   echo '[]'
   exit 0
fi
if [[ "$1" == "issue" && "$2" == "list" ]]; then
   echo '[]'
   exit 0
fi
if [[ "$1" == "api" ]]; then
    args="${@/--paginate/}"
    poll_num="$(cat "${TEST_DIR}/poll_number" 2>/dev/null || echo "0")"
    if [[ "$args" == *"/issues/comments"* && "$args" == *"?per_page=100"* ]]; then
        case "$poll_num" in
            1) cat "${TEST_DIR}/comments_1.json";;
            2) cat "${TEST_DIR}/comments_2.json";;
            3) cat "${TEST_DIR}/comments_3.json";;
            4) cat "${TEST_DIR}/comments_3.json";;
            *) cat "${TEST_DIR}/comments_1.json";;
        esac
        exit 0
    fi
    if [[ "$args" == *"/issues/1/comments"* ]]; then
        case "$poll_num" in
            1) cat "${TEST_DIR}/comments_1.json";;
            2) cat "${TEST_DIR}/comments_2.json";;
            3) cat "${TEST_DIR}/comments_3.json";;
            4) cat "${TEST_DIR}/comments_3.json";;
            *) cat "${TEST_DIR}/comments_1.json";;
        esac
        exit 0
    fi
    if [[ "$args" == *"/issues?state=open"* ]]; then
       echo '[{"number":1}]'
       exit 0
    fi
    echo '[]'
    exit 0
fi
echo '{}'
exit 0
MOCK_EOF
  chmod +x "$mock_gh_dir/gh"

  # Run 4 polls: setup, add ordinary, add follow-up, idempotency check
  for i in 1 2 3 4; do
    echo "$i" > "$test_dir/poll_number"
    MANUL_DIR="$manul_dir" TEST_DIR="$test_dir" PATH="$mock_gh_dir:$PATH" bash "$SCRIPT_DIR/poll.sh" test-org/test-repo 2>/dev/null
  done

  # Assertion 1: All messages share the same conversation
  local conv_id
  conv_id="$(sqlite3 "$poll_db" "SELECT DISTINCT conversationId FROM conversation_messages WHERE repo='test-org/test-repo' AND issueNumber=1;" 2>/dev/null)"
  if [ "$conv_id" != "conv-test-org/test-repo-issue-1" ]; then
    echo "ERROR: Expected conversation 'conv-test-org/test-repo-issue-1', got: '$conv_id'"
    rm -rf "$test_dir"
    return 1
  fi

  # Assertion 2: Exactly 3 messages persisted
  local msg_count
  msg_count="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM conversation_messages WHERE repo='test-org/test-repo' AND issueNumber=1;" 2>/dev/null)"
  if [ "$msg_count" -ne 3 ]; then
    echo "ERROR: Expected 3 conversation_messages, found $msg_count"
    sqlite3 "$poll_db" "SELECT commentId, body FROM conversation_messages ORDER BY createdAt;"
    rm -rf "$test_dir"
    return 1
  fi

  # Assertion 3: Follow-up task context includes the ordinary feedback
  local followup_context
  followup_context="$(sqlite3 "$poll_db" "SELECT context FROM processed_comments WHERE repository='test-org/test-repo' AND issueNumber=1 AND prompt LIKE '%Now implement the change%';" 2>/dev/null)"
  if [ -z "$followup_context" ]; then
    echo "ERROR: Follow-up task has empty context"
    rm -rf "$test_dir"
    return 1
  fi
  if [[ "$followup_context" != *"Also make sure the assertion uses float comparison."* ]]; then
    echo "ERROR: Follow-up context does not include ordinary feedback"
    echo "Context: $followup_context"
    rm -rf "$test_dir"
    return 1
  fi

  # Assertion 4: Idempotency — 4th poll did not add duplicate rows
  local msg_count_after_4th
  msg_count_after_4th="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM conversation_messages WHERE repo='test-org/test-repo' AND issueNumber=1;" 2>/dev/null)"
  if [ "$msg_count_after_4th" -ne 3 ]; then
    echo "ERROR: Expected 3 messages after 4th poll (idempotent), found $msg_count_after_4th"
    rm -rf "$test_dir"
    return 1
  fi

  local task_count_after_4th
  task_count_after_4th="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM processed_comments WHERE repository='test-org/test-repo' AND issueNumber=1;" 2>/dev/null)"
  if [ "$task_count_after_4th" -ne 2 ]; then
    echo "ERROR: Expected 2 tasks after 4th poll (idempotent), found $task_count_after_4th"
    rm -rf "$test_dir"
    return 1
  fi

  rm -rf "$test_dir"
  return 0
}

# =============================================================================
# Test 2: Review-thread — every comment persisted, identity based on root only
# =============================================================================
test_review_thread_regression() {
  local test_dir
  test_dir="$(mktemp -d /tmp/conv-regression-review-XXXXXX)"
  local manul_dir="$test_dir/manul"
  mkdir -p "$manul_dir"

  cat > "$manul_dir/config.json" <<'CFGEOF'
{"automation":{"maxAttemptsBeforeFail":3,"leaseTimeout":900},"reviewers":["mock-reviewer"],"allowedUsers":["test-user","reviewer","author"],"triggers":{"issueCommentTrigger":"/manul","prReviewCommentTrigger":"/manul","issueBodyTrigger":"/manul","fallbackTrigger":"manul"},"signature":"— manul 🐈"}
CFGEOF

  local poll_db="$manul_dir/manul.db"
  sqlite3 "$poll_db" "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$poll_db" "INSERT INTO meta VALUES('baseline','2019-01-01T00:00:00Z');"
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
  sqlite3 "$poll_db" "CREATE TABLE conversation_messages(messageId TEXT PRIMARY KEY, conversationId TEXT NOT NULL, commentId TEXT, repo TEXT, issueNumber INTEGER, author TEXT, body TEXT, commentUrl TEXT, createdAt TEXT, messageType TEXT);"

  cp "$SCRIPT_DIR/manul-pr-review.sh" "$manul_dir/manul-pr-review.sh"
  cp "$SCRIPT_DIR/manul-conversation.sh" "$manul_dir/manul-conversation.sh"
  cp "$SCRIPT_DIR/manul-github-events.sh" "$manul_dir/manul-github-events.sh"

  local mock_gh_dir="$test_dir/mock-gh"
  mkdir -p "$mock_gh_dir"

  # 4 review comments: 101 (root), 102 (reply to 101), 103 (reply to 102), 201 (second root)
  # Only 101 and 201 contain the trigger so they create tasks; all 4 should be persisted.
  cat > "$test_dir/review_comments.json" <<'EOF'
[
  {"id":"101","user":{"login":"test-user"},"body":"/manul Fix the auth module","html_url":"https://github.com/test-org/test-repo/pull/50#discussion_r101","created_at":"2026-09-16T00:00:00Z","in_reply_to_id":null,"path":"src/auth.py","line":42,"diff_hunk":"@@ -40,3 +40,3 @@","original_line":42},
  {"id":"102","user":{"login":"test-user"},"body":"Can you also handle timeout?","html_url":"https://github.com/test-org/test-repo/pull/50#discussion_r102","created_at":"2026-09-16T00:01:00Z","in_reply_to_id":"101","path":"src/auth.py","line":45,"diff_hunk":"@@ -40,3 +40,3 @@","original_line":45},
  {"id":"103","user":{"login":"test-user"},"body":"Good point, added.","html_url":"https://github.com/test-org/test-repo/pull/50#discussion_r103","created_at":"2026-09-16T00:02:00Z","in_reply_to_id":"102","path":"src/auth.py","line":48,"diff_hunk":"@@ -40,3 +40,3 @@","original_line":48},
  {"id":"201","user":{"login":"test-user"},"body":"/manul Add unit tests for the new endpoint","html_url":"https://github.com/test-org/test-repo/pull/50#discussion_r201","created_at":"2026-09-16T00:03:00Z","in_reply_to_id":null,"path":"tests/test_api.py","line":10,"diff_hunk":"@@ -8,3 +8,3 @@","original_line":10}
]
EOF

  cat > "$mock_gh_dir/gh" <<'MOCK_EOF'
#!/bin/bash
set -u
if [[ "$1" == "pr" && "$2" == "list" ]]; then
   echo '[{"number":50,"headRefName":"feature/auth","baseRefName":"main","title":"Auth refactor","url":"https://github.com/test-org/test-repo/pull/50","state":"open"}]'
   exit 0
fi
if [[ "$1" == "issue" && "$2" == "list" ]]; then
   echo '[]'
   exit 0
fi
if [[ "$1" == "api" ]]; then
    args="${@/--paginate/}"
    if [[ "$args" == *"/pulls/comments"* ]]; then
        cat "${TEST_DIR}/review_comments.json"
        exit 0
    fi
    if [[ "$args" == *"/pulls/50/comments"* ]]; then
        cat "${TEST_DIR}/review_comments.json"
        exit 0
    fi
    if [[ "$args" == *"/issues?state=open"* ]]; then
       echo '[]'
       exit 0
    fi
    echo '[]'
    exit 0
fi
echo '{}'
exit 0
MOCK_EOF
  chmod +x "$mock_gh_dir/gh"

  MANUL_DIR="$manul_dir" PATH="$mock_gh_dir:$PATH" bash "$SCRIPT_DIR/poll.sh" test-org/test-repo 2>/dev/null

  # Assertion 1: 2 tasks created (one per trigger comment: 101 and 201)
  local task_count
  task_count="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM processed_comments WHERE repository='test-org/test-repo' AND prNumber=50;" 2>/dev/null)"
  if [ "$task_count" -ne 2 ]; then
    echo "ERROR: Expected 2 tasks, found $task_count"
    sqlite3 "$poll_db" "SELECT commentId, conversationId FROM processed_comments WHERE repository='test-org/test-repo';"
    rm -rf "$test_dir"
    return 1
  fi

  # Assertion 2: 4 conversation messages persisted (all review comments)
  local msg_count
  msg_count="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM conversation_messages WHERE repo='test-org/test-repo' AND issueNumber=50;" 2>/dev/null)"
  if [ "$msg_count" -ne 4 ]; then
    echo "ERROR: Expected 4 conversation_messages, found $msg_count"
    sqlite3 "$poll_db" "SELECT commentId, conversationId, body FROM conversation_messages ORDER BY createdAt;"
    rm -rf "$test_dir"
    return 1
  fi

  # Assertion 3: Comments 101, 102, 103 share review-101 conversation
  local conv_101
  conv_101="$(sqlite3 "$poll_db" "SELECT DISTINCT conversationId FROM conversation_messages WHERE repo='test-org/test-repo' AND issueNumber=50 AND commentId IN ('101','102','103');" 2>/dev/null)"
  if [ "$conv_101" != "conv-test-org/test-repo-review-101" ]; then
    echo "ERROR: Expected 'conv-test-org/test-repo-review-101' for comments 101/102/103, got: '$conv_101'"
    rm -rf "$test_dir"
    return 1
  fi

  # Assertion 4: Comment 201 has its own review-201 conversation
  local conv_201
  conv_201="$(sqlite3 "$poll_db" "SELECT conversationId FROM conversation_messages WHERE repo='test-org/test-repo' AND issueNumber=50 AND commentId='201';" 2>/dev/null)"
  if [ "$conv_201" != "conv-test-org/test-repo-review-201" ]; then
    echo "ERROR: Expected 'conv-test-org/test-repo-review-201' for comment 201, got: '$conv_201'"
    rm -rf "$test_dir"
    return 1
  fi

  # Assertion 5: Idempotency — running poll again does not duplicate messages
  MANUL_DIR="$manul_dir" PATH="$mock_gh_dir:$PATH" bash "$SCRIPT_DIR/poll.sh" test-org/test-repo 2>/dev/null
  local msg_count_after
  msg_count_after="$(sqlite3 "$poll_db" "SELECT COUNT(*) FROM conversation_messages WHERE repo='test-org/test-repo' AND issueNumber=50;" 2>/dev/null)"
  if [ "$msg_count_after" -ne 4 ]; then
    echo "ERROR: Expected 4 messages after second poll (idempotent), found $msg_count_after"
    rm -rf "$test_dir"
    return 1
  fi

  rm -rf "$test_dir"
  return 0
}

# =============================================================================
# Run tests
# =============================================================================
run_test "issue conversation: trigger→ordinary→follow-up preserves context and is idempotent" test_issue_conversation_regression
run_test "review thread: every comment persisted, identity based on root only" test_review_thread_regression

echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed (out of $TOTAL tests)"
echo "═══════════════════════════════════════════════════════════════"

exit "$FAILED"
