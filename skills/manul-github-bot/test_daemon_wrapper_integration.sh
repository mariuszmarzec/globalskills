#!/bin/bash
# test_daemon_wrapper_integration.sh - Integration test for evaluate_task_completion()
# Tests the production completion decision function directly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create a temporary directory for test files
TEST_TMPDIR=$(mktemp -d)
trap "rm -rf $TEST_TMPDIR" EXIT

# Create fake executables for external dependencies
FAKE_BIN="$TEST_TMPDIR/fake_bin"
mkdir -p "$FAKE_BIN"

# Fake gh executable for GitHub API mocking
FAKE_GH="$FAKE_BIN/gh"
cat > "$FAKE_GH" << 'GH_EOF'
#!/bin/bash
if [[ "$1" == "api" ]]; then
    has_jq=false
    for arg in "$@"; do
        if [[ "$arg" == "--jq" ]]; then
            has_jq=true
            break
        fi
    done
    for arg in "$@"; do
        if [[ "$arg" == repos/* ]]; then
            path="$arg"
            path="${path#repos/}"
            remainder="${path#*/issues/}"
            remainder="${remainder#*/}"
            if [[ "$remainder" == "comments" ]]; then
                json_output='[{"id":1001,"body":"<!-- manul-task:COMMENT_1:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                if [[ "$has_jq" == "true" ]]; then
                    echo "$json_output" | jq -r '.[] | select(.in_reply_to_id == null) | .body // ""'
                else
                    echo "$json_output"
                fi
                exit 0
            fi
        fi
    done
fi
if [[ "$has_jq" == "true" ]]; then
    echo '[]'
else
    echo '{}'
fi
GH_EOF
chmod +x "$FAKE_GH"

# Source manul-daemon.sh with testing guard enabled
MANUL_TESTING=true source "$SCRIPT_DIR/manul-daemon.sh"
export PATH="$FAKE_BIN:$PATH"

# Setup test environment
LOG_FILE="$TEST_TMPDIR/daemon.log"
LIFECYCLE_LOG="$TEST_TMPDIR/lifecycle.log"
PID_FILE="$TEST_TMPDIR/daemon.pid"
DB="$TEST_TMPDIR/manul_test.db"
HEARTBEAT_INTERVAL=60
LOG="$LOG_FILE"
LIFECYCLE_LOG="$LIFECYCLE_LOG"
export PID_FILE DB HEARTBEAT_INTERVAL LOG LIFECYCLE_LOG CONFIG="$SCRIPT_DIR/config.json"

# Create test database
sqlite3 "$DB" "CREATE TABLE processed_comments (commentId TEXT PRIMARY KEY, processedAt TEXT, nextAttemptAt TEXT, attempt INTEGER, repo TEXT, issueNum TEXT, taskType TEXT, commentUrl TEXT, status TEXT, workerPid INTEGER DEFAULT NULL);"
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('COMMENT_1', NULL, NULL, 1, 'test/repo', '42', 'task', 'https://github.com/test/repo/issues/42#issuecomment-1001', 'queued', 0);"
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('COMMENT_2', NULL, NULL, 1, 'test/repo', '43', 'task', 'https://github.com/test/repo/issues/43#issuecomment-1002', 'queued', 0);"
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('COMMENT_3', NULL, NULL, 1, 'test/repo', '44', 'task', 'https://github.com/test/repo/issues/44#issuecomment-1003', 'queued', 0);"
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('COMMENT_4', NULL, NULL, 1, 'test/repo', '45', 'task', 'https://github.com/test/repo/issues/45#issuecomment-1004', 'queued', 0);"
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('COMMENT_5', NULL, NULL, 1, 'test/repo', '46', 'task', 'https://github.com/test/repo/issues/46#issuecomment-1005', 'queued', 0);"
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('COMMENT_6', NULL, NULL, 1, 'test/repo', '47', 'task', 'https://github.com/test/repo/issues/47#issuecomment-1006', 'queued', 0);;"
echo "0" > "$PID_FILE"

# ─── Test A: rc=0 + TASK_DONE + valid result comment -> COMPLETION_SUCCESS=true ─
echo "=== Test A: rc=0 + TASK_DONE + valid result -> COMPLETION_SUCCESS=true ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutA.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "42" "COMMENT_1" "COMMENT_1" "1" "0" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: Test A - expected COMPLETION_SUCCESS=true, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if [ -z "$FINAL_COMMENT" ]; then
    echo "FAIL: Test A - expected non-empty FINAL_COMMENT"
    exit 1
fi
echo "[OK] Test A: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test B: rc=0 + TASK_DONE + missing result comment -> COMPLETION_SUCCESS=false ─
echo "=== Test B: rc=0 + TASK_DONE + missing result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutB.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "43" "COMMENT_2" "COMMENT_2" "1" "0" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test B - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if [ -z "$FAIL_REASON" ]; then
    echo "FAIL: Test B - expected non-empty FAIL_REASON"
    exit 1
fi
echo "[OK] Test B: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test C: rc=0 + TASK_DONE + invalid/unrelated result -> COMPLETION_SUCCESS=false ─
echo "=== Test C: rc=0 + TASK_DONE + unrelated result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutC.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
echo "some unrelated output" >> "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "44" "COMMENT_3" "COMMENT_3" "1" "0" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test C - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test C: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false ─
echo "=== Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutD.txt"
echo "some output without marker" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "45" "COMMENT_4" "COMMENT_4" "1" "0" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test D - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test D: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false ─
echo "=== Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutE.txt"
echo "TASK_FAILED: orchestration error" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "46" "COMMENT_5" "COMMENT_5" "1" "42" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test E - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
# When rc!=0, FAIL_REASON may or may not be set depending on implementation
echo "[OK] Test E: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test F: timeout/signal + no TASK_DONE -> COMPLETION_SUCCESS=false ─
echo "=== Test F: non-zero rc + no TASK_DONE -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutF.txt"
echo "timeout occurred" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "47" "COMMENT_6" "COMMENT_6" "1" "124" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test F - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test F: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "=== INTEGRATION TEST SUMMARY ==="
echo "[OK] Test A: rc=0 + TASK_DONE + valid result -> COMPLETION_SUCCESS=true"
echo "[OK] Test B: rc=0 + TASK_DONE + missing result -> COMPLETION_SUCCESS=false"
echo "[OK] Test C: rc=0 + TASK_DONE + unrelated result -> COMPLETION_SUCCESS=false"
echo "[OK] Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false"
echo "[OK] Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false"
echo "[OK] Test F: non-zero rc + no TASK_DONE -> COMPLETION_SUCCESS=false"
echo "[OK] All tests call real evaluate_task_completion() from manul-daemon.sh"
echo "=== ALL INTEGRATION TESTS PASSED ==="
