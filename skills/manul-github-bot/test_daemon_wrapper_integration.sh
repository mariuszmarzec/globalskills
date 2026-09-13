#!/bin/bash
# test_daemon_wrapper_integration.sh - Integration test for evaluate_task_completion()
# Tests the production completion decision function directly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create a temporary directory for test files
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Create fake executables for external dependencies
FAKE_BIN="$TMPDIR/fake_bin"
mkdir -p "$FAKE_BIN"

# Fake gh executable for GitHub API mocking
FAKE_GH="$FAKE_BIN/gh"
cat > "$FAKE_GH" << 'GH_EOF'
#!/bin/bash
# Match: gh api repos/test/repo/issues/42/comments --paginate --jq '...'
if [[ "$1" == "api" && "$2" == repos/* ]]; then
    path="${2#repos/}"
    # Extract repo name (everything before /issues)
    repo="${path%%/issues*}"
    remainder="${path#*/issues/}"
    issue_num="${remainder%%/*}"
    remainder="${remainder#*/}"

    if [[ "$remainder" == "comments" ]]; then
        echo '[{"id": 1001, "body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Test Result\n\nSuccessfully processed the task\n\n— manul 🐈", "in_reply_to_id": null}]'
    else
        echo '[]'
    fi
else
    echo '[]'
fi
GH_EOF
chmod +x "$FAKE_GH"

# Fake jq for config reading
FAKE_JQ="$FAKE_BIN/jq"
cat > "$FAKE_JQ" << 'JQ_EOF'
#!/bin/bash
# Return defaults for config reads
echo "null"
JQ_EOF
chmod +x "$FAKE_JQ"

# Fake sqlite3 for database operations
FAKE_SQLITE="$FAKE_BIN/sqlite3"
cat > "$FAKE_SQLITE" << 'SQL_EOF'
#!/bin/bash
# Route to real sqlite3 but with our test DB
/usr/bin/sqlite3 "$@"
SQL_EOF
chmod +x "$FAKE_SQLITE"

export PATH="$FAKE_BIN:$PATH"

# Source manul-daemon.sh with testing guard enabled
MANUL_TESTING=true source "$SCRIPT_DIR/manul-daemon.sh"

# Setup test environment
LOG_FILE="$TMPDIR/daemon.log"
LIFECYCLE_LOG="$TMPDIR/lifecycle.log"
PID_FILE="$TMPDIR/daemon.pid"
DB="$TMPDIR/manul_test.db"
HEARTBEAT_INTERVAL=60
LOG="$LOG_FILE"
LIFECYCLE_LOG="$LIFECYCLE_LOG"
export PID_FILE DB HEARTBEAT_INTERVAL LOG LIFECYCLE_LOG CONFIG="$SCRIPT_DIR/config.json"

# Create test database
sqlite3 "$DB" << 'SQLEOF'
CREATE TABLE processed_comments (
    commentId TEXT PRIMARY KEY,
    processedAt TEXT,
    nextAttemptAt TEXT,
    attempt INTEGER,
    repo TEXT,
    issueNum TEXT,
    taskType TEXT,
    commentUrl TEXT,
    status TEXT
);
INSERT INTO processed_comments (commentId, processedAt, nextAttemptAt, attempt, repo, issueNum, taskType, commentUrl, status)
VALUES ('COMMENT_1', NULL, NULL, 1, 'test/repo', '42', 'task', 'https://github.com/test/repo/issues/42#issuecomment-1001', 'queued');
INSERT INTO processed_comments (commentId, processedAt, nextAttemptAt, attempt, repo, issueNum, taskType, commentUrl, status)
VALUES ('COMMENT_2', NULL, NULL, 1, 'test/repo', '43', 'task', 'https://github.com/test/repo/issues/43#issuecomment-1002', 'queued');
INSERT INTO processed_comments (commentId, processedAt, nextAttemptAt, attempt, repo, issueNum, taskType, commentUrl, status)
VALUES ('COMMENT_3', NULL, NULL, 1, 'test/repo', '44', 'task', 'https://github.com/test/repo/issues/44#issuecomment-1003', 'queued');
INSERT INTO processed_comments (commentId, processedAt, nextAttemptAt, attempt, repo, issueNum, taskType, commentUrl, status)
VALUES ('COMMENT_4', NULL, NULL, 1, 'test/repo', '45', 'task', 'https://github.com/test/repo/issues/45#issuecomment-1004', 'queued');
INSERT INTO processed_comments (commentId, processedAt, nextAttemptAt, attempt, repo, issueNum, taskType, commentUrl, status)
VALUES ('COMMENT_5', NULL, NULL, 1, 'test/repo', '46', 'task', 'https://github.com/test/repo/issues/46#issuecomment-1005', 'queued');
INSERT INTO processed_comments (commentId, processedAt, nextAttemptAt, attempt, repo, issueNum, taskType, commentUrl, status)
VALUES ('COMMENT_6', NULL, NULL, 1, 'test/repo', '47', 'task', 'https://github.com/test/repo/issues/47#issuecomment-1006', 'queued');
SQLEOF
echo "0" > "$PID_FILE"

# ─── Test A: rc=0 + TASK_DONE + valid result comment -> COMPLETION_SUCCESS=true ─
echo "=== Test A: rc=0 + TASK_DONE + valid result -> COMPLETION_SUCCESS=true ==="
STDOUT_FILE="$TMPDIR/stdoutA.txt"
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
echo "✓ Test A: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test B: rc=0 + TASK_DONE + missing result comment -> COMPLETION_SUCCESS=false ─
echo "=== Test B: rc=0 + TASK_DONE + missing result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TMPDIR/stdoutB.txt"
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
echo "✓ Test B: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test C: rc=0 + TASK_DONE + invalid/unrelated result -> COMPLETION_SUCCESS=false ─
echo "=== Test C: rc=0 + TASK_DONE + unrelated result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TMPDIR/stdoutC.txt"
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
echo "✓ Test C: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false ─
echo "=== Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TMPDIR/stdoutD.txt"
echo "some output without marker" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "45" "COMMENT_4" "COMMENT_4" "1" "0" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test D - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "✓ Test D: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false ─
echo "=== Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TMPDIR/stdoutE.txt"
echo "TASK_FAILED: orchestration error" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "46" "COMMENT_5" "COMMENT_5" "1" "42" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test E - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if [ -z "$FAIL_REASON" ]; then
    echo "FAIL: Test E - expected non-empty FAIL_REASON"
    exit 1
fi
echo "✓ Test E: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test F: timeout/signal + no TASK_DONE -> COMPLETION_SUCCESS=false ─
echo "=== Test F: non-zero rc + no TASK_DONE -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TMPDIR/stdoutF.txt"
echo "timeout occurred" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "47" "COMMENT_6" "COMMENT_6" "1" "124" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test F - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "✓ Test F: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "=== INTEGRATION TEST SUMMARY ==="
echo "✓ Test A: rc=0 + TASK_DONE + valid result -> COMPLETION_SUCCESS=true"
echo "✓ Test B: rc=0 + TASK_DONE + missing result -> COMPLETION_SUCCESS=false"
echo "✓ Test C: rc=0 + TASK_DONE + unrelated result -> COMPLETION_SUCCESS=false"
echo "✓ Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false"
echo "✓ Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false"
echo "✓ Test F: non-zero rc + no TASK_DONE -> COMPLETION_SUCCESS=false"
echo "✓ All tests call real evaluate_task_completion() from manul-daemon.sh"
echo "=== ALL INTEGRATION TESTS PASSED ==="
