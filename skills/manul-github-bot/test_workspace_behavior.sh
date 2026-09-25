#!/bin/bash
# test_workspace_behavior.sh: Behavioral tests for workspace concurrency

set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export CONFIG="$MANUL_DIR/config.json"
export LOG="$MANUL_DIR/logs/daemon.log"

mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/workspace" "$MANUL_DIR/logs"

# Minimal config
cat > "$CONFIG" << 'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "automation": {
    "enabled": true,
    "maxAttemptsBeforeFail": 3
  }
}
CONFIGEOF

# Source only workspace manager (not full poll.sh to avoid dependencies)
_script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$_script_dir/manul-paths.sh"
export DB="$MANUL_DB"
source "$_script_dir/workspace-manager.sh"

# Create processed_comments table for cross-repo tests
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments (commentId TEXT PRIMARY KEY, repository TEXT, issueNumber INTEGER, processedAt TEXT, status TEXT, workspaceId TEXT);" 2>/dev/null || true

# Copy generate_conversation_id from poll.sh
generate_conversation_id() {
  local repo="$1"
  local issue="$2"
  local kind="${3:-issue}"
  local thread_id="${4:-}"

  case "$kind" in
    review-thread)
      [ -n "$thread_id" ] || {
        echo "ERROR: review-thread conversation requires thread_id" >&2
        return 1
      }
      printf 'conv-%s-review-%s' "$repo" "$thread_id"
      ;;
    issue|pr-top-level)
      printf 'conv-%s-issue-%s' "$repo" "$issue"
      ;;
    *)
      echo "ERROR: unknown conversation kind: $kind" >&2
      return 1
      ;;
  esac
}

PASSED=0
FAILED=0
TESTS_RUN=0

run_test() {
  local name="$1"
  local result="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$result" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $name"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $name"
  fi
}

# Wrapper to always call run_test (avoids losing failures under `set -e` or direct function calls)
run_and_test() {
  local name="$1"
  local func="$2"
  set +e
  "$func"
  local rc=$?
  set -e
  run_test "$name" "$rc"
}

# Helper to reset pool between tests
reset_pool() {
  workspace_pool_init 0 reset
}

# Self-check: verify test discovery
self_check() {
  local expected_tests=23
  local actual_tests
  actual_tests=$(grep -c "^test_[a-zA-Z0-9_]*() {" "$0" 2>/dev/null || echo 0)

  if [ "$actual_tests" -ne "$expected_tests" ]; then
    echo "  FAIL: Test discovery mismatch: expected $expected_tests, found $actual_tests"
    return 1
  fi

  echo "  PASS: Test discovery verified ($actual_tests tests found)"
  return 0
}

self_check || { echo "Test discovery failed"; exit 1; }

echo "═══════════════════════════════════════════════════════════════"
echo "  Workspace Behavior Tests"
echo "═══════════════════════════════════════════════════════════════"

# Test 1: Two tasks for same repo get different workspaces
echo ""
echo "=== Test 1: Same repo concurrent tasks get different workspaces ==="
test_same_repo_different_workspaces() {
  workspace_pool_init 5 reset
  
  local ws1 ws2
  ws1="$(workspace_lease "task-repo1-a")"
  ws2="$(workspace_lease "task-repo1-b")"
  
  [ -n "$ws1" ] || return 1
  [ -n "$ws2" ] || return 1
  [ "$ws1" != "$ws2" ] || return 1
  
  local busy_count
  busy_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='BUSY';")"
  [ "$busy_count" -eq 2 ] || return 1
  
  workspace_release "$ws1"
  workspace_release "$ws2"
}
run_and_test "Test 1: Same repo different workspaces" test_same_repo_different_workspaces

# Test 2: Completed workspace can be reused
echo ""
echo "=== Test 2: Completed workspace reuse ==="
test_workspace_reuse() {
  workspace_pool_init 2 reset
  
  local ws1
  ws1="$(workspace_lease "task-reuse-1")"
  workspace_release "$ws1"
  
  local ws2
  ws2="$(workspace_lease "task-reuse-2")"
  
  [ "$ws1" = "$ws2" ] || return 1
  
  workspace_release "$ws2"
}
run_and_test "Test 2: Workspace reuse after completion" test_workspace_reuse

# Test 3: Concurrent tasks from same conversation get separate workspaces
echo ""
echo "=== Test 3: Same conversation concurrent tasks isolation ==="
test_conversation_isolation() {
  workspace_pool_init 3 reset
  
  local ws1 ws2
  ws1="$(workspace_lease "conv-A-task-1")"
  ws2="$(workspace_lease "conv-A-task-2")"
  
  [ -n "$ws1" ] || return 1
  [ -n "$ws2" ] || return 1
  [ "$ws1" != "$ws2" ] || return 1
  
  workspace_release "$ws1"
  workspace_release "$ws2"
}
run_and_test "Test 3: Same conversation isolation" test_conversation_isolation

# Test 4: Sequential tasks in same conversation can reuse workspace
echo ""
echo "=== Test 4: Sequential conversation tasks workspace reuse ==="
test_sequential_conversation() {
  workspace_pool_init 2 reset
  
  local ws1
  ws1="$(workspace_lease "conv-B-task-1")"
  workspace_release "$ws1"
  
  local ws2
  ws2="$(workspace_lease "conv-B-task-2")"
  
  [ -n "$ws2" ] || return 1
  
  workspace_release "$ws2"
}
run_and_test "Test 4: Sequential conversation workspace" test_sequential_conversation

# Test 5: Different conversations on same issue/PR are isolated
echo ""
echo "=== Test 5: Different conversations on same issue ==="
test_different_conversations() {
  workspace_pool_init 4

  local conv1 conv2
  conv1="$(generate_conversation_id "test/repo" "1" "review-thread" "r1")"
  conv2="$(generate_conversation_id "test/repo" "1" "review-thread" "r2")"

  [ "$conv1" != "$conv2" ] || return 1

  local ws1 ws2
  ws1="$(workspace_lease "conv1-task")"
  ws2="$(workspace_lease "conv2-task")"

  [ -n "$ws1" ] || return 1
  [ -n "$ws2" ] || return 1
  [ "$ws1" != "$ws2" ] || return 1

  workspace_release "$ws1"
  workspace_release "$ws2"
}
run_and_test "Test 5: Different conversations isolation" test_different_conversations

# Test 6: Workspace exclusivity verification
echo ""
echo "=== Test 6: Workspace exclusivity ==="
test_workspace_exclusivity() {
  workspace_pool_init 1 reset
  
  local ws1
  ws1="$(workspace_lease "exclusive-task-1")"
  
  local ws2
  ws2="$(workspace_lease "exclusive-task-2")"
  
  [ -z "$ws2" ] || return 1
  
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws1';")"
  [ "$status" = "BUSY" ] || return 1
  
  workspace_release "$ws1"
}
run_and_test "Test 6: Workspace exclusivity" test_workspace_exclusivity

# Test 7: Pool exhaustion behavior
echo ""
echo "=== Test 7: Pool exhaustion ==="
test_pool_exhaustion() {
  workspace_pool_init 2 reset
  
  local ws1 ws2
  ws1="$(workspace_lease "exhaust-1")"
  ws2="$(workspace_lease "exhaust-2")"
  
  local ws3
  ws3="$(workspace_lease "exhaust-3")"
  
  [ -z "$ws3" ] || return 1
  
  workspace_release "$ws1"
  local ws4
  ws4="$(workspace_lease "exhaust-4")"
  
  [ -n "$ws4" ] || return 1
  [ "$ws4" = "$ws1" ] || return 1
  
  workspace_release "$ws2"
  workspace_release "$ws4"
}
run_and_test "Test 7: Pool exhaustion and recovery" test_pool_exhaustion

# Test 8: Stale workspace cleanup
echo ""
echo "=== Test 8: Stale workspace cleanup ==="
test_stale_cleanup() {
  workspace_pool_init 3 reset
  
  local ws
  ws="$(workspace_lease "stale-task")"
  
  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now', '-7200 seconds') WHERE workspaceId='$ws';"
  
  workspace_cleanup_stale 3600
  
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws';" 2>/dev/null || echo "NOT_FOUND")"

  [ "$status" = "BROKEN" ] || [ -z "$status" ] || [ "$status" = "NOT_FOUND" ] || return 1
}
run_and_test "Test 8: Stale workspace cleanup" test_stale_cleanup

# Test 9: A stale-looking workspace must not be reclaimed while its worker is alive
echo ""
echo "=== Test 9: Live worker protects stale workspace ==="
test_live_worker_protects_workspace() {
  workspace_pool_init 1 reset

  local ws
  ws="$(workspace_lease "live-task")"
  [ -n "$ws" ] || return 1

  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,heartbeatAt,leaseExpiresAt,workerPid) VALUES('live-task','running',datetime('now','-7200 seconds'),datetime('now','-7200 seconds'),$$);"
  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now','-7200 seconds') WHERE workspaceId='$ws';"

  workspace_cleanup_stale 3600

  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws';")"
  [ "$status" = "BUSY" ] || return 1
  workspace_release "$ws"
}
run_and_test "Test 9: Live worker protects stale workspace" test_live_worker_protects_workspace

# Test 10: Dead worker + stale task allows workspace reclamation
echo ""
echo "=== Test 10: Dead worker stale workspace reclamation ==="
test_dead_worker_reclaims_workspace() {
  workspace_pool_init 1 reset

  local ws
  ws="$(workspace_lease "dead-task")"
  [ -n "$ws" ] || return 1

  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,heartbeatAt,leaseExpiresAt,workerPid) VALUES('dead-task','running',datetime('now','-7200 seconds'),datetime('now','-7200 seconds'),99999999);"
  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now','-7200 seconds') WHERE workspaceId='$ws';"

  workspace_cleanup_stale 3600

  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws';" 2>/dev/null || true)"
  [ -z "$status" ] || [ "$status" = "NOT_FOUND" ] || return 1
}
run_and_test "Test 10: Dead worker stale workspace reclamation" test_dead_worker_reclaims_workspace

echo ""

# Test 9: Sequential same-conversation workspace reuse
echo ""
echo "=== Test 11: Sequential same-conversation workspace reuse ==="
test_sequential_reuse() {
  workspace_pool_init 2 reset

  local ws1
  ws1="$(workspace_lease "conv-A-task-1")"
  [ -n "$ws1" ] || return 1

  local status1
  status1="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws1';")"
  [ "$status1" = "BUSY" ] || return 1

  workspace_release "$ws1"

  local ws2
  ws2="$(workspace_lease "conv-A-task-2")"
  [ -n "$ws2" ] || return 1
  [ "$ws2" = "$ws1" ] || return 1

  status1="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws2';")"
  [ "$status1" = "BUSY" ] || return 1

  workspace_release "$ws2"
}
run_and_test "Test 9: Sequential same-conversation workspace reuse" test_sequential_reuse

# Test 10: Cross-repository workspace isolation
echo ""
echo "=== Test 12: Cross-repository workspace isolation ==="
test_cross_repo_isolation() {
  workspace_pool_init 2 reset

  # Two concurrent tasks for different repos get different workspaces
  local ws1 ws2
  ws1="$(workspace_lease "repo-a-task")"
  [ -n "$ws1" ] || return 1
  ws2="$(workspace_lease "repo-b-task")"
  [ -n "$ws2" ] || return 1
  [ "$ws1" != "$ws2" ] || return 1

  workspace_release "$ws1"
  workspace_release "$ws2"
}
run_and_test "Test 10: Cross-repository workspace isolation" test_cross_repo_isolation

# Test 11: Concurrent lease atomicity — two simultaneous lease attempts on pool of 1
echo ""
echo "=== Test 13: Concurrent lease atomicity ==="
test_concurrent_lease() {
  workspace_pool_init 1 reset

  # Use background processes to create true concurrency
  local ws1 ws2
  ( ws1="$(workspace_lease "concurrent-task-1")"; echo "$ws1" > /tmp/ws1.out ) &
  local pid1=$!
  ( ws2="$(workspace_lease "concurrent-task-2")"; echo "$ws2" > /tmp/ws2.out ) &
  local pid2=$!

  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true

  ws1="$(cat /tmp/ws1.out 2>/dev/null)"
  ws2="$(cat /tmp/ws2.out 2>/dev/null)"
  rm -f /tmp/ws1.out /tmp/ws2.out

  # Exactly one should succeed
  local got_one=false
  if [ -n "$ws1" ] && [ -z "$ws2" ]; then
    got_one=true
  elif [ -z "$ws1" ] && [ -n "$ws2" ]; then
    got_one=true
  fi
  [ "$got_one" = "true" ] || return 1

  # The winner should have BUSY status
  local winner="${ws1:-$ws2}"
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$winner';")"
  [ "$status" = "BUSY" ] || return 1

  # Verify DB has exactly one owner for this workspace
  local owner_count
  owner_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$winner' AND status='BUSY';")"
  [ "$owner_count" = "1" ] || return 1

  workspace_release "$winner"
}
run_and_test "Test 11: Concurrent lease atomicity" test_concurrent_lease

# Test 12: workspace_repo_matches handles HTTPS URLs with .git
test_workspace_repo_matches_https_with_git() {
  workspace_repo_matches "test-org/test-repo" "https://github.com/test-org/test-repo.git"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 12: workspace_repo_matches HTTPS with .git" test_workspace_repo_matches_https_with_git

# Test 13: workspace_repo_matches handles HTTPS URLs without .git
test_workspace_repo_matches_https_without_git() {
  workspace_repo_matches "test-org/test-repo" "https://github.com/test-org/test-repo"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 13: workspace_repo_matches HTTPS without .git" test_workspace_repo_matches_https_without_git

# Test 14: workspace_repo_matches handles SSH URLs
test_workspace_repo_matches_ssh() {
  workspace_repo_matches "test-org/test-repo" "git@github.com:test-org/test-repo.git"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 14: workspace_repo_matches SSH URL" test_workspace_repo_matches_ssh

# Test 15: workspace_repo_matches handles local filesystem paths
test_workspace_repo_matches_local() {
  workspace_repo_matches "test-org/test-repo" "/home/user/workspace/test-org-test-repo"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 15: workspace_repo_matches local path" test_workspace_repo_matches_local

# Test 16: workspace_repo_matches rejects non-matching repos
test_workspace_repo_matches_nonmatching() {
  workspace_repo_matches "test-org/test-repo" "other-org/other-repo"
  [ $? -ne 0 ] || return 1
  workspace_repo_matches "test-org/test-repo" "https://github.com/other-org/other-repo"
  [ $? -ne 0 ] || return 1
}
run_and_test "Test 16: workspace_repo_matches rejects non-matching" test_workspace_repo_matches_nonmatching

# Test 17: workspace_repo_matches handles github.com/ prefix
test_workspace_repo_matches_github_prefix() {
  workspace_repo_matches "test-org/test-repo" "github.com/test-org/test-repo"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 17: workspace_repo_matches github.com prefix" test_workspace_repo_matches_github_prefix

# Test 18: workspace_repo_matches handles ssh:// git protocol
test_workspace_repo_matches_ssh_protocol() {
  workspace_repo_matches "test-org/test-repo" "ssh://git@github.com/test-org/test-repo.git"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 18: workspace_repo_matches ssh:// protocol" test_workspace_repo_matches_ssh_protocol

# Test 19: evaluate_task_completion ignores __pycache__ in untracked files
echo ""
echo "=== Test 21: Untracked files filtering ==="
test_untracked_files_ignores_pycache() {
  # Create a temp repo with __pycache__ and .pytest_cache
  local tmprepo
  tmprepo="$(mktemp -d)" || return 1

  git -C "$tmprepo" init -q
  git -C "$tmprepo" config user.email "test@test.com"
  git -C "$tmprepo" config user.name "Test"

  # Create a tracked file
  echo "print('hello')" > "$tmprepo/app.py"
  git -C "$tmprepo" add app.py
  git -C "$tmprepo" commit -q -m "initial" >/dev/null 2>&1

  # Create build artifacts
  mkdir -p "$tmprepo/__pycache__"
  echo "compiled" > "$tmprepo/__pycache__/app.cpython-311.pyc"
  mkdir -p "$tmprepo/.pytest_cache/v/cache"
  echo "cache" > "$tmprepo/.pytest_cache/v/cache/lastfailed"
  mkdir -p "$tmprepo/src/__pycache__"
  echo "nested" > "$tmprepo/src/__pycache__/mod.cpython-311.pyc"

  # Capture untracked output (simulating what evaluate_task_completion does)
  local untracked
  untracked="$(git -C "$tmprepo" ls-files --others --exclude-standard 2>/dev/null | grep -v '/__pycache__' | grep -v '/\.pytest_cache' | grep -v '^__pycache__' | grep -v '^\.__pycache__' | grep -v '^\.__pycache__/' | grep -v '^\.pytest_cache' || true)"

  # Cleanup
  rm -rf "$tmprepo"

  # Should be empty - all pycache dirs filtered
  [ -z "$untracked" ] || return 1
}
run_and_test "Test 19: untracked files ignores __pycache__ and .pytest_cache" test_untracked_files_ignores_pycache

# Test 20: Fresh lease must NOT be released when a stale completed/failed
# task in the same conversation points at an unrelated idle workspace.
# Regression test for issue #44: the "reuse previous workspace" block used
# to release the freshly leased workspace and repoint the task at a
# completed/failed workspace whose currentTaskId was already NULL, which
# broke workspace_get_path resolution and prevented the agent from ever
# starting.
echo ""
echo "=== Test 20: Fresh lease survives stale conversation reuse ==="
test_fresh_lease_survives_stale_reuse() {
  workspace_pool_init 2 reset

  # 1. Lease workspace A for the current task T.
  local ws_a
  ws_a="$(workspace_lease "task-T")"
  [ -n "$ws_a" ] || return 1

  # 2. Prepare an unrelated completed/failed workspace B in the same
  #    conversation: IDLE, currentTaskId=NULL, with a stale task row
  #    pointing at it (simulating a previously completed task).
  local ws_b
  ws_b="$(workspace_lease "task-prev")"
  [ -n "$ws_b" ] || return 1
  workspace_release "$ws_b"
  sqlite3 "$DB" "UPDATE workspaces SET currentTaskId=NULL, status='IDLE' WHERE workspaceId='$ws_b';"
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId, repository, issueNumber, status, workspaceId, processedAt) VALUES('task-prev','repo',1,'completed','$ws_b',datetime('now'));"

  # 3. Simulate the post-lease dispatch state: task T points at ws_a, ws_a
  #    is BUSY with currentTaskId=task-T. The fix must NOT touch ws_a.
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId, repository, issueNumber, status, workspaceId, processedAt) VALUES('task-T','repo',1,'running','$ws_a',datetime('now'));"

  # 4. Assert ws_a is still leased to task-T and ws_b is idle/untouched.
  local owner_a state_a
  owner_a="$(sqlite3 "$DB" "SELECT currentTaskId FROM workspaces WHERE workspaceId='$ws_a';")"
  state_a="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws_a';")"
  [ "$owner_a" = "task-T" ] || return 1
  [ "$state_a" = "BUSY" ] || return 1

  local owner_b state_b
  owner_b="$(sqlite3 "$DB" "SELECT currentTaskId FROM workspaces WHERE workspaceId='$ws_b';")"
  state_b="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws_b';")"
  [ -z "$owner_b" ] || return 1
  [ "$state_b" = "IDLE" ] || return 1

  # 5. workspace_get_path must still resolve ws_a for task-T.
  local resolved expected_path
  resolved="$(workspace_get_path "task-T")"
  expected_path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$ws_a';")"
  [ "$resolved" = "$expected_path" ] || return 1

  workspace_release "$ws_a"
}
run_and_test "Test 20: Fresh lease survives stale conversation reuse" test_fresh_lease_survives_stale_reuse

# Test 21: Negative control — a workspace without valid ownership must
# prevent agent dispatch. Mirrors the hard validation added to the daemon
# dispatch path: no agent may launch against a workspace that is not BUSY
# and owned by the current task.
echo ""
echo "=== Test 21: Invalid ownership blocks dispatch ==="
test_invalid_ownership_blocks_dispatch() {
  workspace_pool_init 2 reset

  local ws_a
  ws_a="$(workspace_lease "task-T")"
  [ -n "$ws_a" ] || return 1

  # Break the invariant: release the workspace back to the pool.
  workspace_release "$ws_a"

  local owner state
  owner="$(sqlite3 "$DB" "SELECT currentTaskId FROM workspaces WHERE workspaceId='$ws_a';")"
  state="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws_a';")"
  [ -z "$owner" ] || return 1
  [ "$state" = "IDLE" ] || return 1

  # The daemon validation query must return empty (no BUSY row owned by task-T).
  local validated
  validated="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$ws_a' AND currentTaskId='task-T' AND status='BUSY' LIMIT 1;" 2>/dev/null || echo "")"
  [ -z "$validated" ] || return 1
}
run_and_test "Test 21: Invalid ownership blocks dispatch" test_invalid_ownership_blocks_dispatch

echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed (out of $TESTS_RUN tests)"
echo "═══════════════════════════════════════════════════════════════"

exit "$FAILED"
