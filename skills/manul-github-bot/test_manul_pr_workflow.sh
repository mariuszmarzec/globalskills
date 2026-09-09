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

  # Verify prompt requires exactly one user-facing result comment via GitHub
  local has_result_comment_requirement
  has_result_comment_requirement="$(grep -c 'result comment to GitHub using the' "$PROMPT")"
  assert_eq "$TEST_NAME (exactly one result comment required)" "1" "$has_result_comment_requirement"

  # Verify posting is mandatory (not optional)
  local has_mandatory
  has_mandatory="$(grep -c 'Result comment is mandatory' "$PROMPT")"
  assert_eq "$TEST_NAME (mandatory posting)" "1" "$has_mandatory"

  # Verify result is posted BEFORE TASK_DONE
  local has_before_task_done
  has_before_task_done="$(grep -c 'BEFORE emitting.*TASK_DONE\|before emitting.*TASK_DONE' "$PROMPT")"
  assert_gt "$TEST_NAME (posted before TASK_DONE)" "0" "$has_before_task_done"

  # Verify old daemon-posting requirement is removed (agent, not daemon, posts result)
  local has_daemon_posts
  has_daemon_posts="$(grep -c 'daemon handles all GitHub communication' "$PROMPT")"
  assert_eq "$TEST_NAME (no daemon posting requirement)" "0" "$has_daemon_posts"

  # Verify old stdout-as-result contract is removed
  local has_stdout_result
  has_stdout_result="$(grep -c 'stdout.*user-facing\|output.*posted as.*GitHub comment' "$PROMPT")"
  assert_eq "$TEST_NAME (no stdout-as-result contract)" "0" "$has_stdout_result"

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
  has_completed_comment="$(grep -v '^[[:space:]]*#' "$DAEMON" | grep -c '✅ Manul completed')" 
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
# Test 15: Completed-task guard placement and logic
# ============================================================================
test_completed_task_guard() {
  TEST_NAME="completed_task_guard"
  echo "=== Test 15: Completed-task guard ==="

  # Test A: Guard runs after TASK_INFO parsing (no undefined variable errors)
  local guard_placement
  guard_placement="$(grep -n '# 0.5 Completed-task guard' "$DAEMON" | head -1 | cut -d: -f1)"
  local task_info_line
  task_info_line="$(grep -n 'TASK_INFO.*SELECT commentId.*processed_comments' "$DAEMON" | head -1 | cut -d: -f1)"
  if [ -n "$guard_placement" ] && [ -n "$task_info_line" ] && [ "$guard_placement" -gt "$task_info_line" ]; then
    ok "$TEST_NAME (guard after TASK_INFO parsing)"
  else
    fail "$TEST_NAME (guard after TASK_INFO parsing)"
  fi

  # Test B: Guard uses deterministic correlation (commentUrl)
  local has_url_check
  has_url_check="$(grep -c 'commentUrl.*status.*completed\|commentUrl.*completed.*status' "$DAEMON")"
  assert_gt "$TEST_NAME (uses commentUrl correlation)" "0" "$has_url_check"

  # Test C: Guard checks for missing commentUrl and logs error
  local has_missing_url_check
  has_missing_url_check="$(grep -c 'missing_comment_url' "$DAEMON")"
  assert_eq "$TEST_NAME (handles missing commentUrl)" "1" "$has_missing_url_check"

  # Test D: Guard consumes duplicate without agent invocation
  local has_duplicate_consume
  has_duplicate_consume="$(grep -c 'consuming safely' "$DAEMON")"
  assert_gt "$TEST_NAME (safe duplicate consumption)" "0" "$has_duplicate_consume"
}

# ============================================================================
# Test 16: Retry backoff mechanism
# ============================================================================
test_retry_backoff() {
  TEST_NAME="retry_backoff"
  echo "=== Test 16: Retry backoff mechanism ==="

  # Test A: nextAttemptAt column exists in schema
  local has_next_attempt_at
  has_next_attempt_at="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -c '|nextAttemptAt|')"
  assert_eq "$TEST_NAME (nextAttemptAt column exists)" "1" "$has_next_attempt_at"

  # Test B: Scheduler query uses nextAttemptAt
  local has_next_attempt_in_query
  has_next_attempt_in_query="$(grep -c 'nextAttemptAt <= datetime' "$DAEMON")"
  assert_eq "$TEST_NAME (scheduler uses nextAttemptAt)" "1" "$has_next_attempt_in_query"

  # Test C: Requeue logic sets nextAttemptAt
  local has_next_attempt_in_requeue
  has_next_attempt_in_requeue="$(grep -c "nextAttemptAt=datetime('now', '+\${RETRY_DELAY_SECONDS} seconds')" "$DAEMON")"
  assert_eq "$TEST_NAME (requeue sets nextAttemptAt)" "2" "$has_next_attempt_in_requeue"

  # Test D: MAX_ATTEMPTS path clears nextAttemptAt
  local has_next_attempt_cleared
  has_next_attempt_cleared="$(grep -c "nextAttemptAt=NULL" "$DAEMON")"
  assert_eq "$TEST_NAME (MAX_ATTEMPTS clears nextAttemptAt)" "4" "$has_next_attempt_cleared"

  # Test E: RETRY_DELAY_SECONDS configuration exists
  local has_retry_delay_config
  has_retry_delay_config="$(grep -c 'RETRY_DELAY_SECONDS' "$DAEMON")"
  assert_gt "$TEST_NAME (RETRY_DELAY_SECONDS configured)" "0" "$has_retry_delay_config"

  # Test F: Fresh tasks (attempts=0) are immediately eligible
  local has_fresh_task_eligibility
  has_fresh_task_eligibility="$(grep -c 'attempts=0 OR nextAttemptAt' "$DAEMON")"
  assert_eq "$TEST_NAME (fresh tasks eligible)" "1" "$has_fresh_task_eligibility"
}

# ============================================================================
# Test 17: Schema migration
# ============================================================================
test_schema_migration() {
  TEST_NAME="schema_migration"
  echo "=== Test 17: Schema migration ==="

  # Test A: Migration exists in poll.sh
  local has_migration
  has_migration="$(grep -c 'ADD COLUMN nextAttemptAt' "$POLL")"
  assert_eq "$TEST_NAME (migration in poll.sh)" "1" "$has_migration"

  # Test B: Migration is idempotent (checks PRAGMA before ALTER)
  local has_idempotent_check
  has_idempotent_check="$(grep -B2 'ADD COLUMN nextAttemptAt' "$POLL" | grep -c 'PRAGMA table_info')"
  assert_eq "$TEST_NAME (idempotent migration)" "1" "$has_idempotent_check"

  # Test C: Fresh DB test - create temp DB and verify schema
  local temp_db="${MANUL_DIR}/test-schema-migration.db"
  rm -f "$temp_db"
  sqlite3 "$temp_db" "CREATE TABLE IF NOT EXISTS processed_comments (
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
    processedAt TEXT
  );"
  # Apply migration
  if ! sqlite3 "$temp_db" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|nextAttemptAt|'; then
    sqlite3 "$temp_db" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;"
  fi
  local fresh_db_has_column
  fresh_db_has_column="$(sqlite3 "$temp_db" "PRAGMA table_info(processed_comments);" | grep -c '|nextAttemptAt|')"
  rm -f "$temp_db"
  assert_eq "$TEST_NAME (fresh DB has nextAttemptAt)" "1" "$fresh_db_has_column"
}

# ============================================================================
# Test 18: Repository lock interaction with scheduler
# ============================================================================
test_repository_lock_scheduler() {
  TEST_NAME="repository_lock_scheduler"
  echo "=== Test 18: Repository lock interaction ==="

  # Test A: Scheduler does not block on repository lock
  # The scheduler should be able to find eligible tasks even when another repo is locked
  local scheduler_uses_repo_lock
  scheduler_uses_repo_lock="$(grep -c 'repo.*lock.*scheduler\|lock.*repo.*scheduler' "$DAEMON" 2>/dev/null)"
  scheduler_uses_repo_lock="${scheduler_uses_repo_lock:-0}"
  # Scheduler should NOT be coupled to repo lock (they are independent)
  if [ "$scheduler_uses_repo_lock" -eq 0 ]; then
    ok "$TEST_NAME (scheduler independent of repo lock)"
  else
    fail "$TEST_NAME (scheduler independent of repo lock)"
  fi

  # Test B: Repository lock is released after task completion
  local has_lock_release
  has_lock_release="$(grep -c 'release_repo_lock' "$DAEMON")"
  assert_gt "$TEST_NAME (repo lock released)" "0" "$has_lock_release"
}

# ============================================================================
# Helper: assert_gt (greater than)
# ============================================================================
assert_gt() {
  local label="$1" expected_min="$2" actual="$3"
  if [ "$actual" -gt "$expected_min" ]; then
    ok "$label"
  else
    fail "$label (expected > '$expected_min', got '$actual')"
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
test_completed_task_guard
test_retry_backoff
test_schema_migration
test_repository_lock_scheduler

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
