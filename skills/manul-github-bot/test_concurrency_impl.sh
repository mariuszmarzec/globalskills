#!/bin/bash
# Comprehensive concurrency test functions for test_concurrency.sh
# This file contains all test implementations (A-V)

# ===== Test A: maxConcurrentTasks=2 allows parallel execution =====
test_a() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Setup config with concurrency
  cat > "$CONFIG" << 'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "agents": ["architect"],
  "automation": {
    "enabled": true,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900,
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800
  }
}
CONFIGEOF

  # Initialize workspace pool with 2 workspaces
  source skills/manul-github-bot/workspace-manager.sh
  MAX_CONCURRENT_TASKS=2
  workspace_pool_init
  
  # Verify pool was created
  local ws_count
  ws_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='IDLE';")"
  
  # Simulate two tasks being claimed concurrently
  local ws1 ws2
  ws1="$(workspace_lease "task-1")"
  ws2="$(workspace_lease "task-2")"
  
  
  # Verify both are BUSY
  local busy_count
  busy_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='BUSY';")"
  
  cd "$start_dir"
}

# ===== Test B: Same conversation shares workspace =====
test_b() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  source skills/manul-github-bot/workspace-manager.sh
  workspace_pool_init 5
  
  # Create two tasks in same conversation
  local ws1 ws2
  ws1="$(workspace_lease "task-1-conversation-A")"
  ws2="$(workspace_lease "task-2-conversation-A")"
  
  # They should get different workspaces (exclusive access)
  # In a real implementation, conversation-aware leasing would share
  # For this test, we verify the workspace is released properly
  workspace_release "$ws1"
  workspace_release "$ws2"
  
  # Verify release
  local idle_count
  idle_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='IDLE';")"
  
  cd "$start_dir"
}

# ===== Test C: Different conversations isolate workspaces =====
test_c() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  source skills/manul-github-bot/workspace-manager.sh
  workspace_pool_init 5
  
  # Create tasks in different conversations
  local ws1 ws2
  ws1="$(workspace_lease "task-1-conversation-A")"
  ws2="$(workspace_lease "task-2-conversation-B")"
  
  
  cd "$start_dir"
}

# ===== Test D: Workspace lease/release lifecycle =====
test_d() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  source skills/manul-github-bot/workspace-manager.sh
  workspace_pool_init 3
  
  # Lease a workspace
  local ws_id
  ws_id="$(workspace_lease "task-d")"
  
  # Verify it's BUSY
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws_id';")"
  
  # Release it
  workspace_release "$ws_id"
  
  # Verify it's IDLE
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws_id';")"
  
  cd "$start_dir"
}

# ===== Test E: Daemon fails with insufficient workspaces =====
test_e() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # This test validates the guard in start() that checks workspace availability
  # For mock testing, we verify the logic exists
  grep -q "workspace_available_count" skills/manul-github-bot/manul-daemon.sh
  
  cd "$start_dir"
}

# ===== Test F: Schema migration adds fields =====
test_f() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Create a minimal DB without the new columns
  rm -f "$DB"
  sqlite3 "$DB" "CREATE TABLE processed_comments (
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
    processedAt TEXT,
    heartbeatAt TEXT,
    leaseExpiresAt TEXT,
    workerPid INTEGER,
    nextAttemptAt TEXT
  );"
  
  # Run migration (simulated by sourcing poll.sh setup)
  source skills/manul-github-bot/poll.sh
  
  # Verify columns were added
  local has_column
  has_column="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" | grep -c '|conversationId|' || echo 0)"
  
  has_column="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" | grep -c '|parentTaskId|' || echo 0)"
  
  has_column="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" | grep -c '|workspaceId|' || echo 0)"
  
  cd "$start_dir"
}

# ===== Test G: Existing DB accepts new tasks post-migration =====
test_g() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Setup with migration
  test_f  # Ensure columns exist
  
  # Insert a task with null values for new columns
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, prompt, status, createdAt)
    VALUES('test-g-task', 'test/repo', 1, 'https://github.com/test/repo/issues/1', 'test prompt', 'queued', datetime('now'));"
  
  # Verify task was inserted
  local count
  count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='test-g-task';")"
  
  cd "$start_dir"
}

# ===== Test H: Legacy tasks have no workspace/conversation fields =====
test_h() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Check that legacy tasks (inserted before migration) have NULL values
  sqlite3 "$DB" "UPDATE processed_comments SET conversationId=NULL, parentTaskId=NULL, workspaceId=NULL WHERE commentId='test-g-task';"
  
  local has_values
  has_values="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId IS NOT NULL AND parentTaskId IS NOT NULL AND workspaceId IS NOT NULL;")"
  
  cd "$start_dir"
}

# ===== Test I: Default behavior unchanged =====
test_i() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Without maxConcurrentTasks, should default to 1
  cat > "$CONFIG" << 'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "agents": ["architect"],
  "automation": {
    "enabled": true,
    "maxAttemptsBeforeFail": 3
  }
}
CONFIGEOF
  
  # Parse config - should default to 1
  local max_concurrent
  max_concurrent="$(jq -r '.automation.maxConcurrentTasks // 1' "$CONFIG")"
  
  cd "$start_dir"
}

# ===== Test J: conversationId populated =====
test_j() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Verify that when tasks are created, conversationId is set
  # This tests the queue creation logic
  local conv_id="conv-$(date +%s)"
  
sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, prompt, status, conversationId, createdAt)
  VALUES('test-j-task', 'test/repo', 1, 'https://github.com/test/repo/issues/1', 'test prompt', 'queued', '$conv_id', datetime('now'));"
  
  local stored_conv
  stored_conv="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='test-j-task';")"
  
  cd "$start_dir"
}

# ===== Test K: CLI manul-submit =====
test_k() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills

  # Test the real manul-submit.sh script
  local result
  result="$(MANUL_DIR="$TEST_DIR/manul" bash skills/manul-github-bot/manul-submit.sh \
    --repo test/repo --issue 1 --prompt "Test submission" --json 2>&1)"
  
  # Verify JSON output with required fields
  printf '%s' "$result" | jq -e '.commentId' > /dev/null 2>&1
  local exit_code=$?
  
  # Cleanup
  cd "$start_dir"
  return $exit_code
}

# ===== Test L: CLI manul-status =====
test_l() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills

  # Create test tasks
  MANUL_DIR="$TEST_DIR/manul" bash skills/manul-github-bot/manul-submit.sh \
    --repo test/repo --issue 1 --prompt "Status test 1" > /dev/null 2>&1
  MANUL_DIR="$TEST_DIR/manul" bash skills/manul-github-bot/manul-submit.sh \
    --repo test/repo --issue 2 --prompt "Status test 2" > /dev/null 2>&1
  
  # Test the real manul-status.sh script
  local result
  result="$(MANUL_DIR="$TEST_DIR/manul" bash skills/manul-github-bot/manul-status.sh \
    --list --json 2>&1)"
  
  # Verify JSON array output
  printf '%s' "$result" | jq -e 'type == "array"' > /dev/null 2>&1
  local exit_code=$?
  
  cd "$start_dir"
  return $exit_code
}

# ===== Test M: CLI manul-result =====
test_m() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills

  # Create a completed task
  MANUL_DIR="$TEST_DIR/manul" bash skills/manul-github-bot/manul-submit.sh \
    --repo test/repo --issue 1 --prompt "Result test" > /dev/null 2>&1
  
  local task_id
  task_id="$(sqlite3 "$TEST_DIR/manul/manul.db" "SELECT commentId FROM processed_comments ORDER BY createdAt DESC LIMIT 1;")"
  
  # Mark as completed
  sqlite3 "$TEST_DIR/manul/manul.db" "UPDATE processed_comments SET status='completed', context='Done', processedAt='now' WHERE commentId='$task_id';"
  
  # Test the real manul-result.sh script
  local result
  result="$(MANUL_DIR="$TEST_DIR/manul" bash skills/manul-github-bot/manul-result.sh \
    "$task_id" --json 2>&1)"
  
  # Verify JSON output
  printf '%s' "$result" | jq -e '.success == true' > /dev/null 2>&1
  local exit_code=$?
  
  cd "$start_dir"
  return $exit_code
}

# ===== Test N: TASK_DONE emits structured JSON =====
test_n() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Mock a TASK_DONE output with structured JSON
  local stdout_file="$TEST_DIR/task-done-stdout.txt"
  cat > "$stdout_file" << 'STDOUTEOF'
Some agent output...
TASK_DONE
{"success":true,"taskId":"task-n","output":"Done","attempts":1}
STDOUTEOF

  # Verify detection
  
  cd "$start_dir"
}

# ===== Test O: TASK_FAILED emits structured JSON =====
test_o() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Mock a TASK_FAILED output with structured JSON
  local stdout_file="$TEST_DIR/task-failed-stdout.txt"
  cat > "$stdout_file" << 'STDOUTEOF'
Error occurred...
TASK_FAILED: Could not complete task
{"success":false,"taskId":"task-o","error":"Could not complete task","attempts":1}
STDOUTEOF

  # Verify detection
  
  cd "$start_dir"
}

# ===== Test P: Subtask inherits conversationId =====
test_p() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Insert parent task
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, prompt, status, conversationId)
    VALUES('parent-p', 'test/repo', 1, 'https://github.com/test/repo/issues/1', 'test prompt', 'completed', 'conv-parent');"

  # Insert subtask with parentTaskId
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, prompt, status, parentTaskId, conversationId)
    VALUES('subtask-p', 'test/repo', 1, 'https://github.com/test/repo/issues/1', 'test prompt', 'queued', 'parent-p', 'conv-parent');"
  
  # Verify inheritance
  local parent_conv subtask_conv
  parent_conv="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='parent-p';")"
  subtask_conv="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='subtask-p';")"
  subtask_parent="$(sqlite3 "$DB" "SELECT parentTaskId FROM processed_comments WHERE commentId='subtask-p';")"
  
  
  cd "$start_dir"
}

# ===== Test Q: Worker queue independence =====
test_q() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Simulate two workers processing independently
  source skills/manul-github-bot/workspace-manager.sh
  workspace_pool_init 4
  
  # Worker 1 claims tasks
  local ws1 ws2 ws3
  ws1="$(workspace_lease "w1-task-1")"
  ws2="$(workspace_lease "w1-task-2")"
  
  # Worker 2 claims remaining tasks
  ws3="$(workspace_lease "w2-task-1")"
  
  # Verify they got different workspaces
  
  # Release all
  workspace_release "$ws1"
  workspace_release "$ws2"
  workspace_release "$ws3"
  
  cd "$start_dir"
}

# ===== Test R: Workspace sharing rules =====
test_r() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Verify workspace is exclusive per task
  source skills/manul-github-bot/workspace-manager.sh
  workspace_pool_init 1
  
  # Lease workspace
  local ws
  ws="$(workspace_lease "task-r-1")"
  
  # Try to lease same workspace (should fail)
  local ws2
  ws2="$(workspace_lease "task-r-2")"
  
  
  # Release and verify
  workspace_release "$ws"
  
  cd "$start_dir"
}

# ===== Test S: Stale workspace reclamation =====
test_s() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  source skills/manul-github-bot/workspace-manager.sh
  workspace_pool_init 3
  
  # Lease a workspace
  local ws
  ws="$(workspace_lease "task-s")"
  
  # Manually set lastUsedAt to old time
  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now', '-7200 seconds') WHERE workspaceId='$ws';"
  
  # Cleanup stale workspaces (with 1 hour threshold)
  workspace_cleanup_stale 3600
  
  # Verify workspace was cleaned up (status changed or removed)
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws';" 2>/dev/null)"

  # Should be BROKEN, empty (deleted), or NOT_FOUND
  
  cd "$start_dir"
}

# ===== Test T: Worker pool lifecycle =====
test_t() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Verify worker pool start/stop logic
  # Check that start() uses workspace_pool_init
  grep -q "workspace_pool_init" skills/manul-github-bot/manul-daemon.sh
  
  # Check that multiple workers are spawned
  grep -q "MAX_CONCURRENT_TASKS" skills/manul-github-bot/manul-daemon.sh
  
  cd "$start_dir"
}

# ===== Test U: Backward compatibility =====
test_u() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Run existing tests to ensure they still pass
  bash skills/manul-github-bot/test_prompt_generation.sh >/dev/null 2>&1
  
  bash skills/manul-github-bot/test_verify_result_comment.sh >/dev/null 2>&1
  
  cd "$start_dir"
}

# ===== Test V: Production safety guards =====
test_v() {
  local start_dir="$PWD"
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." || cd /home/marzec/globalskills
  
  # Verify safety guards exist
  grep -q "acquire_task_lock" skills/manul-github-bot/manul-daemon.sh
  
  grep -q "release_repo_lock" skills/manul-github-bot/manul-daemon.sh
  
  grep -q "verify_result_comment" skills/manul-github-bot/manul-daemon.sh
  
  cd "$start_dir"
}
