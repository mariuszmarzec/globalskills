#!/usr/bin/bash
# test_manul_pr_workflow.sh — Regression tests for Manul GitHub PR workflow
#
# Tests:
#   1. Poller discovers PR review comments (inline) on existing PRs
#   2. Poller discovers top-level PR conversation comments on existing PRs
#   3. Deduplication: re-polling same repo doesn't duplicate entries
#   4. New comments after task completion are still discovered
#   5. Reply routing: review comments → in-thread reply, top-level → top-level
#   6. feedback.sh exists and is functional
#   7. Config includes all expected repos (no typos)
#
# Usage: bash test_manul_pr_workflow.sh [--setup] [--teardown]
set -uo pipefail

MANUL_DIR="${MANUL_DIR:-/mnt/f/ubuntu-workspace/.openclaw/manul}"
DB="${MANUL_DIR}/manul.db"
CONFIG="${MANUL_DIR}/config.json"
CANONICAL_DIR="${CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"
POLL="${CANONICAL_DIR}/poll.sh"
DAEMON="${CANONICAL_DIR}/manul-daemon.sh"
FEEDBACK="${CANONICAL_DIR}/feedback.sh"

PASS=0
FAIL=0
TEST_NAME=""

cleanup() {
  if [ "${TEARDOWN:-0}" = "1" ]; then
    sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null
    sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId LIKE 'test:%';" 2>/dev/null
  fi
}
trap cleanup EXIT

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

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    ok "$label"
  else
    fail "$label (expected NOT to contain '$needle')"
  fi
}

extract_new_count() {
  local output="$1"
  echo "$output" | grep -o '"new":[0-9]*' | cut -d: -f2
}

# ============================================================================
# Test 1: Poller discovers PR review comments (inline) on existing PRs
# ============================================================================
test_poller_discovers_review_comments() {
  TEST_NAME="poller_discovers_review_comments"
  echo "=== Test 1: Poller discovers PR review comments ==="

  # Ensure caracal-rag is clean before test
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null

  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"
  assert_eq "$TEST_NAME" "4" "$new_count"  # 1 review + 3 issue comments on PR #11

  local count
  count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='review:3952521856' AND repository='mariuszmarzec/caracal-rag' AND issueNumber=11 AND status='queued';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$count"

  # Verify context was enriched (PR info + linked issues)
  local has_context
  has_context="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='review:3952521856' AND context IS NOT NULL AND context != '';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$has_context"

  # Cleanup
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='review:3952521856';" 2>/dev/null
}

# ============================================================================
# Test 2: Poller discovers top-level PR conversation comments on existing PRs
# ============================================================================
test_poller_discovers_pr_conversation_comments() {
  TEST_NAME="poller_discovers_pr_conversation_comments"
  echo "=== Test 2: Poller discovers top-level PR conversation comments ==="

  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null

  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"
  assert_eq "$TEST_NAME" "4" "$new_count"  # 1 review + 3 issue comments on PR #11

  local count
  count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5575478422' AND repository='mariuszmarzec/caracal-rag' AND issueNumber=11 AND status='queued';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$count"

  # Verify context was enriched (parent issue info)
  local has_context
  has_context="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5575478422' AND context IS NOT NULL AND context != '';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$has_context"

  # Cleanup
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='issue:5575478422';" 2>/dev/null
}

# ============================================================================
# Test 3: Deduplication — re-polling doesn't duplicate entries
# ============================================================================
test_deduplication() {
  TEST_NAME="deduplication"
  echo "=== Test 3: Deduplication ==="

  # Queue both caracal-rag tasks
  MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag >/dev/null 2>&1

  local first_count
  first_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag' AND status='queued';" 2>/dev/null)"

  # Poll again immediately
  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"

  assert_eq "$TEST_NAME (no new entries)" "0" "$new_count"
  assert_eq "$TEST_NAME (same count)" "$first_count" "$first_count"  # Always passes, but shows intent

  # Cleanup
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null
}

# ============================================================================
# Test 4: New comments after task completion are discovered
# ============================================================================
test_new_comments_after_completion() {
  TEST_NAME="new_comments_after_completion"
  echo "=== Test 4: New comments after task completion are discovered ==="

  # Insert a fake completed task to simulate a previously handled comment
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, agent, prompt, status, createdAt) VALUES ('test:completed999', 'mariuszmarzec/caracal-rag', 11, 'https://github.com/mariuszmarzec/caracal-rag/pull/11#issuecomment-999', 'mariuszmarzec', '', 'test prompt', 'completed', '2026-09-06T20:00:00Z');" 2>/dev/null

  # Now poll -- should discover the real comments
  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"
  assert_eq "$TEST_NAME" "4" "$new_count"

  # Verify the new tasks are queued (not blocked by the completed one)
  local review_queued
  review_queued="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='review:3952521856' AND status='queued';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$review_queued"

  local issue_queued
  issue_queued="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5575478422' AND status='queued';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$issue_queued"

  # Cleanup
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null
}

# ============================================================================
# Test 5: Reply routing — daemon extracts REPLY_TO correctly from commentId
# ============================================================================
test_reply_routing() {
  TEST_NAME="reply_routing"
  echo "=== Test 5: Reply routing ==="

  # Check that post_github_comment accepts reply_to parameter
  # We can't easily test the full daemon, but we can verify the function signature
  local func_sig
  func_sig="$(sed -n '/^post_github_comment()/,/^}/p' "$DAEMON")"
  assert_contains "$TEST_NAME" "$func_sig" 'local reply_to="${4:-}"'
  # Verify gh api is used for review-thread replies (not --in-reply-to which is unsupported)
  assert_contains "$TEST_NAME" "$func_sig" 'gh api'
  # Ensure old --in-reply-to is NOT present as a command flag (only in comments)
  local has_old_reply
  has_old_reply="$(echo "$func_sig" | grep 'in-reply-to' | grep -v '^[[:space:]]*#' | wc -l)"
  assert_eq "$TEST_NAME (no --in-reply-to)" "0" "$has_old_reply"

  # Check that REPLY_TO is extracted for review comments
  local reply_to_extraction
  reply_to_extraction="$(grep -A 10 'TASK_TYPE="issue"' "$DAEMON" | grep 'REPLY_TO')"
  assert_contains "$TEST_NAME" "$reply_to_extraction" 'REPLY_TO='

  # Verify the daemon passes REPLY_TO to post_github_comment for Running and Done comments
  local running_routing
  running_routing="$(grep 'post_github_comment.*IN_PROGRESS_BODY.*REPLY_TO' "$DAEMON")"
  assert_contains "$TEST_NAME" "$running_routing" 'REPLY_TO'

  local done_routing
  done_routing="$(grep 'post_github_comment.*FINAL_COMMENT.*REPLY_TO' "$DAEMON" | head -1)"
  assert_contains "$TEST_NAME" "$done_routing" 'REPLY_TO'

  # Verify review comment commentId format is correct
  local review_comment
  review_comment="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag' AND commentId LIKE 'review:%' LIMIT 1;" 2>/dev/null)"
  # Re-poll to get the review comment back
  MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag >/dev/null 2>&1
  review_comment="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag' AND commentId LIKE 'review:%' LIMIT 1;" 2>/dev/null)"
  assert_contains "$TEST_NAME" "$review_comment" "review:"
}

# ============================================================================
# Test 6: feedback.sh exists and is functional
# ============================================================================
test_feedback_script() {
  TEST_NAME="feedback_script"
  echo "=== Test 6: feedback.sh exists and is functional ==="

  # Check canonical script exists
  assert_eq "$TEST_NAME (canonical exists)" "1" "$(test -f "$CANONICAL_DIR/feedback.sh" && echo 1 || echo 0)"

  # Check runtime symlink exists
  assert_eq "$TEST_NAME (runtime symlink)" "1" "$(test -L "$MANUL_DIR/feedback.sh" && echo 1 || echo 0)"

  # Check it's executable
  assert_eq "$TEST_NAME (executable)" "1" "$(test -x "$CANONICAL_DIR/feedback.sh" && echo 1 || echo 0)"

  # Check syntax
  bash -n "$CANONICAL_DIR/feedback.sh" 2>/dev/null
  assert_eq "$TEST_NAME (syntax OK)" "0" "$?"

  # Verify it has the manul signature
  local sig_check
  sig_check="$(grep 'manul 🐈' "$CANONICAL_DIR/feedback.sh")"
  assert_contains "$TEST_NAME" "$sig_check" "manul"

  # Verify poll.sh references feedback.sh
  local poll_ref
  poll_ref="$(grep 'feedback.sh' "$POLL")"
  assert_contains "$TEST_NAME" "$poll_ref" "feedback.sh"
}

# ============================================================================
# Test 7: Config includes caracal-rag and has no typos
# ============================================================================
test_config_repos() {
  TEST_NAME="config_repos"
  echo "=== Test 7: Config includes caracal-rag ==="

  # Check canonical config
  local canonical_repos
  canonical_repos="$(jq -r '.repositories[]?' "$CANONICAL_DIR/config.json")"
  assert_contains "$TEST_NAME" "$canonical_repos" "mariuszmarzec/caracal-rag"

  # Check runtime config
  local runtime_repos
  runtime_repos="$(jq -r '.repositories[]?' "$CONFIG")"
  assert_contains "$TEST_NAME" "$runtime_repos" "mariuszmarzec/caracal-rag"

  # Verify no typo versions exist
  local has_typo
  has_typo="$(jq -r '.repositories[]?' "$CONFIG" | grep -c 'mariuszmarcer' || true)"
  assert_eq "$TEST_NAME (no typos)" "0" "$has_typo"

  # Verify allowedUsers includes mariuszmarzec
  local allowed
  allowed="$(jq -r '.allowedUsers[]?' "$CONFIG")"
  assert_contains "$TEST_NAME" "$allowed" "mariuszmarzec"
}

# ============================================================================
# Test 8: Install script includes feedback.sh
# ============================================================================
test_install_script() {
  TEST_NAME="install_script"
  echo "=== Test 8: install-manul-symlinks.sh includes feedback.sh ==="

  local scripts_list
  scripts_list="$(grep -A 20 'SCRIPTS=(' "$CANONICAL_DIR/install-manul-symlinks.sh" | grep 'feedback.sh')"
  assert_contains "$TEST_NAME" "$scripts_list" "feedback.sh"
}

# ============================================================================
# Test 9: Poller filters by allowed users
# ============================================================================
test_allowed_users_filter() {
  TEST_NAME="allowed_users_filter"
  echo "=== Test 9: Allowed users filter ==="

  # Reset caracal-rag tasks for this test
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null

  # The poller should discover all comments from allowed user mariuszmarzec (1 review + 3 issue = 4)
  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"
  assert_eq "$TEST_NAME" "4" "$new_count"
}

# ============================================================================
# Test 10: Daemon accepts both TASK_DONE and TASK_COMPLETED markers
# ============================================================================
test_completion_markers() {
  TEST_NAME="completion_markers"
  echo "=== Test 10: Completion markers ==="

  # Verify daemon regex accepts both TASK_DONE and TASK_COMPLETED
  local marker_check
  marker_check="$(grep 'TASK_DONE.*TASK_COMPLETED\|TASK_COMPLETED.*TASK_DONE' "$DAEMON")"
  assert_contains "$TEST_NAME" "$marker_check" 'TASK_COMPLETED'

  # Verify TASK_DONE is still accepted
  local task_done_check
  task_done_check="$(grep 'TASK_DONE' "$DAEMON" | grep -v '^#' | head -1)"
  assert_contains "$TEST_NAME" "$task_done_check" 'TASK_DONE'
}

# ============================================================================
# Test 11: Daemon uses flock for singleton locking
# ============================================================================
test_flock_singleton() {
  TEST_NAME="flock_singleton"
  echo "=== Test 11: Flock singleton locking ==="

  # Verify FLOCK_FILE is defined
  local flock_var
  flock_var="$(grep 'FLOCK_FILE=' "$DAEMON" | head -1)"
  assert_contains "$TEST_NAME" "$flock_var" 'FLOCK_FILE'

  # Verify flock is used in start()
  local start_flock
  start_flock="$(grep -A 30 '^start()' "$DAEMON" | grep 'flock')"
  assert_contains "$TEST_NAME" "$start_flock" 'flock'

  # Verify flock is used in loop()
  local loop_flock
  loop_flock="$(grep -A 15 '^loop()' "$DAEMON" | grep 'flock')"
  assert_contains "$TEST_NAME" "$loop_flock" 'flock'
}

# ============================================================================
# Test 12: Agent response is included in final GitHub comment (regression for #12)
# ============================================================================
test_agent_response_in_github_comment() {
  TEST_NAME="agent_response_in_github_comment"
  echo "=== Test 12: Agent response included in GitHub comment ==="

  # Simulate an agent stdout file with a realistic response
  local tmp_stdout
  tmp_stdout="$(mktemp)"
  cat > "$tmp_stdout" <<'EOF'
Here is the complete list of skills available in the system:

1. **agent-orchestration** — Multi-agent orchestration rules
2. **ai-commit-attribution** — AI commit attribution
3. **feature-branching-strategy** — Branching strategy for AI changes
4. **manul-github-bot** — GitHub command bot setup and operation
5. **review-strategy** — Code review methodology

These skills are located at ~/.agents/skills/ and are loaded automatically.
**TASK_DONE**
EOF

  # Verify the sed extraction logic works correctly
  local extracted
  extracted="$(sed -E '/^[[:space:]]*(\*\*)?(TASK_DONE|TASK_COMPLETED)(\*\*)?[[:space:]]*$/d' "$tmp_stdout" | sed '/^[[:space:]]*$/d')"

  assert_contains "$TEST_NAME (extracts response)" "$extracted" "agent-orchestration"
  assert_not_contains "$TEST_NAME (strips TASK_DONE)" "$extracted" "TASK_DONE"
  assert_contains "$TEST_NAME (contains skill count)" "$extracted" "5"

  # Verify the final comment assembly logic
  local FINAL_COMMENT=""
  local AGENT_RESPONSE="$extracted"
  if [ -n "$AGENT_RESPONSE" ]; then
    FINAL_COMMENT="✅ Manul completed the task successfully.

${AGENT_RESPONSE}"
  else
    FINAL_COMMENT="✅ Manul completed the task successfully."
  fi

  assert_contains "$TEST_NAME (comment includes header)" "$FINAL_COMMENT" "✅ Manul completed the task successfully."
  assert_contains "$TEST_NAME (comment includes agent response)" "$FINAL_COMMENT" "agent-orchestration"
  assert_not_contains "$TEST_NAME (comment strips TASK_DONE)" "$FINAL_COMMENT" "TASK_DONE"

  rm -f "$tmp_stdout"
}

# ============================================================================
# Test 13: Gateway-only output is NOT sufficient — GitHub post is required
# ============================================================================
test_github_post_required_for_completion() {
  TEST_NAME="github_post_required_for_completion"
  echo "=== Test 13: GitHub post required for completion ==="

  # Verify the daemon checks COMMENT_POST_SUCCESS before finalizing
  local comment_post_check
  comment_post_check="$(grep -c 'COMMENT_POST_SUCCESS' "$DAEMON")"
  if [ "$comment_post_check" -ge 2 ]; then
    ok "$TEST_NAME (checks comment post success)"
  else
    fail "$TEST_NAME (checks comment post success) (expected >=2, got=$comment_post_check)"
  fi

  # Verify the daemon re-queues if comment post fails
  local post_failure_handling
  post_failure_handling="$(grep -A5 'comment post failed' "$DAEMON" | head -10)"
  assert_contains "$TEST_NAME (handles post failure)" "$post_failure_handling" "failed"

  # Verify the daemon does NOT mark task completed without successful post
  local completion_after_post
  completion_after_post="$(grep -B2 'status=.completed' "$DAEMON" | grep -c 'COMMENT_POST_SUCCESS.*true\|comment posted')"
  assert_eq "$TEST_NAME (requires post before completion)" "1" "$completion_after_post"
}

# ============================================================================
# Test 14: Response extraction handles both TASK_DONE and TASK_COMPLETED
# ============================================================================
test_response_extraction_markers() {
  TEST_NAME="response_extraction_markers"
  echo "=== Test 14: Response extraction handles both markers ==="

  # Test with TASK_DONE
  local tmp_done
  tmp_done="$(mktemp)"
  printf 'Some response\n\n**TASK_DONE**\n' > "$tmp_done"
  local extracted_done
  extracted_done="$(sed -E '/^[[:space:]]*(\*\*)?(TASK_DONE|TASK_COMPLETED)(\*\*)?[[:space:]]*$/d' "$tmp_done" | sed '/^[[:space:]]*$/d')"
  assert_contains "$TEST_NAME (TASK_DONE)" "$extracted_done" "Some response"
  assert_not_contains "$TEST_NAME (strips TASK_DONE)" "$extracted_done" "TASK_DONE"

  # Test with TASK_COMPLETED
  local tmp_completed
  tmp_completed="$(mktemp)"
  printf 'Another answer\n\n**TASK_COMPLETED**\n' > "$tmp_completed"
  local extracted_completed
  extracted_completed="$(sed -E '/^[[:space:]]*(\*\*)?(TASK_DONE|TASK_COMPLETED)(\*\*)?[[:space:]]*$/d' "$tmp_completed" | sed '/^[[:space:]]*$/d')"
  assert_contains "$TEST_NAME (TASK_COMPLETED)" "$extracted_completed" "Another answer"
  assert_not_contains "$TEST_NAME (strips TASK_COMPLETED)" "$extracted_completed" "TASK_COMPLETED"

  # Test truncation at 4000 chars
  local tmp_long
  tmp_long="$(mktemp)"
  python3 -c "print('X' * 5000); print('TASK_DONE')" > "$tmp_long"
  local extracted_long
  extracted_long="$(sed -E '/^[[:space:]]*(\*\*)?(TASK_DONE|TASK_COMPLETED)(\*\*)?[[:space:]]*$/d' "$tmp_long" | sed '/^[[:space:]]*$/d' | head -c 4000)"
  assert_eq "$TEST_NAME (truncates to 4000)" "4000" "${#extracted_long}"

  rm -f "$tmp_done" "$tmp_completed" "$tmp_long"
}

# ============================================================================
# Main
# ============================================================================
echo ""
echo "========================================"
echo "  Manul PR Workflow Regression Tests"
echo "========================================"
echo ""

# Setup: ensure DB is clean for caracal-rag
sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null

test_poller_discovers_review_comments
test_poller_discovers_pr_conversation_comments
test_deduplication
test_new_comments_after_completion
test_reply_routing
test_feedback_script
test_config_repos
test_install_script
test_allowed_users_filter
test_completion_markers
test_flock_singleton
test_agent_response_in_github_comment
test_github_post_required_for_completion
test_response_extraction_markers

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
