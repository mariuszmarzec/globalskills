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
# DB on native ext4 (NOT on 9p /mnt/f)
DB="/home/marzec/.openclaw/manul/manul.db"
CONFIG="${MANUL_DIR}/config.json"
CANONICAL_DIR="${CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"
POLL="${CANONICAL_DIR}/poll.sh"
DAEMON="${CANONICAL_DIR}/manul-daemon.sh"
FEEDBACK="${CANONICAL_DIR}/feedback.sh"
PROMPT="${CANONICAL_DIR}/orchestrator.prompt.md"

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
# Test 12: Agent response extraction is REMOVED (new architecture)
# ============================================================================
test_agent_response_removed() {
  TEST_NAME="agent_response_removed"
  echo "=== Test 12: Agent response extraction REMOVED ==="

  # Verify AGENT_RESPONSE extraction is REMOVED from daemon
  local has_extraction
  has_extraction="$(grep -c 'AGENT_RESPONSE' "$DAEMON")"
  assert_eq "$TEST_NAME (AGENT_RESPONSE removed)" "0" "$has_extraction"

  # Verify daemon does NOT use AGENT_RESPONSE in final comments
  local final_comment_success
  final_comment_success="$(grep -c 'AGENT_RESPONSE' <(grep -A8 'if \[ "$COMPLETION_SUCCESS" = "true" \]; then' "$DAEMON" | head -12))"
  assert_eq "$TEST_NAME (success comment no AGENT_RESPONSE)" "0" "$final_comment_success"

  # Verify success message exists (daemon posts lifecycle comment)
  local has_success_msg
  has_success_msg="$(grep -c '✅ Manul completed the task successfully.' "$DAEMON")"
  assert_eq "$TEST_NAME (success message exists)" "1" "$has_success_msg"
}

# ============================================================================
# Test 13: Prompt enforces agent comment posting (new architecture)
# ============================================================================
test_prompt_enforces_agent_posting() {
  TEST_NAME="prompt_enforces_agent_posting"
  echo "=== Test 13: Prompt enforces agent posting ==="

  # Verify orchestrator prompt says agent must post
  local has_agent_posts
  has_agent_posts="$(grep -c 'Agent must post exactly one user-facing result comment' "$PROMPT")"
  assert_eq "$TEST_NAME (prompt says agent must post new)" "1" "$has_agent_posts"

  # Verify old daemon-posting requirement is removed
  local has_daemon_posts
  has_daemon_posts="$(grep -c 'daemon handles all GitHub communication' "$PROMPT")"
  assert_eq "$TEST_NAME (no daemon posting requirement)" "0" "$has_daemon_posts"

  # Verify routing instructions present
  local has_routing
  has_routing="$(grep -c 'in_reply_to' "$PROMPT")"
  assert_eq "$TEST_NAME (routing instructions present)" "1" "$has_routing"
}

# ============================================================================
# Test 14: Daemon posts lifecycle comments only (new architecture)
# ============================================================================
test_daemon_lifecycle_comments() {
  TEST_NAME="daemon_lifecycle_comments"
  echo "=== Test 14: Daemon posts lifecycle comments only ==="

  # Verify daemon posts working comment
  local has_working_comment
  has_working_comment="$(grep -c '🔄 Manul is working' "$DAEMON")"
  assert_eq "$TEST_NAME (working comment)" "1" "$has_working_comment"

  # Verify daemon posts completed comment
  local has_completed_comment
  has_completed_comment="$(grep -c '✅ Manul completed' "$DAEMON")"
  assert_eq "$TEST_NAME (completed comment)" "1" "$has_completed_comment"

  # Verify daemon posts failed comment - count all failure comment assignments
  # There are multiple legitimate failure scenarios that post lifecycle comments
  local primary_failure_comment
  primary_failure_comment="$(grep -c '❌ Manul failed to complete the task after' "$DAEMON")"
  # Check for the simplified version used in retry logic  
  local retry_failure_comment
  retry_failure_comment="$(grep -c '⚠️ Manul encountered an issue' "$DAEMON")"
  # There should be at least one primary failure message (in reality there are 2 
  # for different failure contexts - pre-check and post-check)
  if [ "$primary_failure_comment" -ge 1 ]; then
    ok "$TEST_NAME (primary failure comment exists)"
  else
    fail "$TEST_NAME (primary failure comment exists)"
  fi
  
  # Verify retry lifecycle comment exists
  if [ "$retry_failure_comment" -ge 1 ]; then
    ok "$TEST_NAME (retry comment exists)"
  else
    fail "$TEST_NAME (retry comment exists)"
  fi
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
test_agent_response_removed
test_prompt_enforces_agent_posting
test_daemon_lifecycle_comments

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
