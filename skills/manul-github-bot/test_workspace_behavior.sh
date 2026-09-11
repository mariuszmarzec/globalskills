#!/bin/bash
# test_workspace_behavior.sh: Behavioral tests for workspace concurrency

set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export DB="$MANUL_DIR/manul.db"
export CONFIG="$MANUL_DIR/config.json"
export LOG="$TEST_DIR/daemon.log"

mkdir -p "$MANUL_DIR/tasks"
mkdir -p "$MANUL_DIR/workspaces"

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
source /home/marzec/globalskills-temp/skills/manul-github-bot/workspace-manager.sh

# Copy generate_conversation_id from poll.sh
generate_conversation_id() {
  local repo="$1"
  local issue="$2"
  local comment_url="${3:-}"
  
  if [ -n "$comment_url" ]; then
    local url_hash
    url_hash="$(printf '%s' "$comment_url" | md5sum | cut -d' ' -f1 | cut -c1-8)"
    printf 'conv-%s-%s-%s' "$repo" "$issue" "$url_hash"
  else
    printf 'conv-%s-%s' "$repo" "$issue"
  fi
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

# Self-check: verify test discovery
self_check() {
  local expected_tests=8
  local actual_tests
  actual_tests=$(grep -c "^test_\w*() {" "$0" 2>/dev/null || echo 0)

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
  workspace_pool_init 5
  
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
  workspace_pool_init 2
  
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
  workspace_pool_init 3
  
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
  workspace_pool_init 2
  
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
  conv1="$(generate_conversation_id "test/repo" "1" "https://github.com/test/repo/issues/1#discussion_r1")"
  conv2="$(generate_conversation_id "test/repo" "1" "https://github.com/test/repo/issues/1#discussion_r2")"
  
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
  workspace_pool_init 1
  
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
  workspace_pool_init 2
  
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
  workspace_pool_init 3
  
  local ws
  ws="$(workspace_lease "stale-task")"
  
  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now', '-7200 seconds') WHERE workspaceId='$ws';"
  
  workspace_cleanup_stale 3600
  
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws';" 2>/dev/null || echo "NOT_FOUND")"

  [ "$status" = "BROKEN" ] || [ -z "$status" ] || [ "$status" = "NOT_FOUND" ] || return 1
}
run_and_test "Test 8: Stale workspace cleanup" test_stale_cleanup

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed (out of $TESTS_RUN tests)"
echo "═══════════════════════════════════════════════════════════════"

[ "$FAILED" -eq 0 ]
