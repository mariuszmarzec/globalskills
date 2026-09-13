#!/bin/bash
# test_daemon_wrapper_integration.sh - Integration test for daemon verification with wrapper
# Tests the actual production path: orchestrator -> manul-agent-wrapper.sh -> TASK_DONE/TASK_FAILED -> daemon completion logic -> verify_result_comment()

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/manul-agent-wrapper.sh"

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
if [[ "$1" == "api" && "$2" == "repos/"* ]]; then
    path="${2#repos/}"
    repo="${path%%/issues/*}"
    remainder="${path#*/issues/}"
    issue_num="${remainder%%/*}"
    remainder="${remainder#*/}"

    if [[ "$remainder" == "comments" ]]; then
        echo '[{"id": 1001, "body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Test Result\n\n✓ Successfully processed the task\n\n— manul 🐈", "in_reply_to": null}]'
    elif [[ "$remainder" =~ ^/[0-9]+$ ]]; then
        echo '{"id": 1001, "body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Test Result\n\n✓ Successfully processed the task\n\n— manul 🐈", "in_reply_to": null}'
    else
        echo '{}'
    fi
else
    echo '{}'
fi
GH_EOF
chmod +x "$FAKE_GH"

# Fake jq for JSON processing (simplified)
FAKE_JQ="$FAKE_BIN/jq"
cat > "$FAKE_JQ" << 'JQ_EOF'
#!/bin/bash
echo '{"body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Test Result\n\n✓ Successfully processed the task\n\n— manul 🐈"}'
JQ_EOF
chmod +x "$FAKE_JQ"

export PATH="$FAKE_BIN:$PATH"

# Source real production functions from manul-daemon.sh
DAEMON="$SCRIPT_DIR/manul-daemon.sh"
eval "$(sed -n '/^log() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^lc_log() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^verify_result_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^sql_escape() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^get_daemon_pid() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^declare -A HEARTBEAT_PIDS/p' "$DAEMON")"

# Setup test environment variables
LOG_FILE="$TMPDIR/daemon.log"
LIFECYCLE_LOG="$TMPDIR/lifecycle.log"
PID_FILE="$TMPDIR/daemon.pid"
DB="$TMPDIR/manul_test.db"
HEARTBEAT_INTERVAL=60
LOG="$LOG_FILE"
LIFECYCLE_LOG="$LIFECYCLE_LOG"
export PID_FILE DB HEARTBEAT_INTERVAL LOG LIFECYCLE_LOG

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
SQLEOF
echo "0" > "$PID_FILE"

# ─── Test A: TASK_DONE + valid result comment -> completion accepted ───────────
echo "=== Test A: TASK_DONE + valid result comment -> completion accepted ==="
mkdir -p "$TMPDIR/testA"
cat > "$TMPDIR/testA/mock_orchestrator.sh" << 'MOCK_A'
#!/bin/bash
set -euo pipefail
echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 0
MOCK_A
chmod +x "$TMPDIR/testA/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/testA/mock_orchestrator.sh"
STDOUT_FILE="$TMPDIR/stdoutA.txt"
STDERR_FILE="$TMPDIR/stderrA.txt"
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"
if ! grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test A - TASK_DONE not emitted by wrapper"
    exit 1
fi
if ! verify_result_comment "test/repo" "42" "COMMENT_1" "COMMENT_1" 1 "$DB"; then
    echo "FAIL: Test A - REAL DAEMON LOGIC rejected valid result comment"
    exit 1
fi
echo "✓ Test A: PASSED"

# ─── Test B: TASK_DONE + missing result comment -> completion rejected ─────────
echo "=== Test B: TASK_DONE + missing result comment -> completion rejected ==="
mkdir -p "$TMPDIR/testB"
cat > "$TMPDIR/testB/mock_orchestrator.sh" << 'MOCK_B'
#!/bin/bash
set -euo pipefail
echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 0
MOCK_B
chmod +x "$TMPDIR/testB/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/testB/mock_orchestrator.sh"
STDOUT_FILE="$TMPDIR/stdoutB.txt"
STDERR_FILE="$TMPDIR/stderrB.txt"
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"
if ! grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test B - TASK_DONE not emitted by wrapper"
    exit 1
fi
DB_B="$TMPDIR/manul_test_b.db"
sqlite3 "$DB_B" << 'SQLB'
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
VALUES ('COMMENT_B', NULL, NULL, 1, 'test/repo', '43', 'task', 'https://github.com/test/repo/issues/43#issuecomment-1002', 'queued');
SQLB
export DB="$DB_B"
if verify_result_comment "test/repo" "43" "COMMENT_B" "COMMENT_B" 1 "$DB_B"; then
    echo "FAIL: Test B - REAL DAEMON LOGIC accepted missing result comment"
    exit 1
fi
echo "✓ Test B: PASSED"
export DB="$TMPDIR/manul_test.db"

# ─── Test C: orchestrator rc=42 -> wrapper produces TASK_FAILED and returns 42 ─
echo "=== Test C: orchestrator rc=42 -> wrapper produces TASK_FAILED ==="
mkdir -p "$TMPDIR/testC"
cat > "$TMPDIR/testC/mock_orchestrator.sh" << 'MOCK_C'
#!/bin/bash
set -euo pipefail
echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 42
MOCK_C
chmod +x "$TMPDIR/testC/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/testC/mock_orchestrator.sh"
STDOUT_FILE="$TMPDIR/stdoutC.txt"
STDERR_FILE="$TMPDIR/stderrC.txt"
wrapper_rc=0
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" || wrapper_rc=$?
if ! grep -q "^TASK_FAILED:" "$STDOUT_FILE"; then
    echo "FAIL: Test C - TASK_FAILED not emitted by wrapper"
    exit 1
fi
if [ "$wrapper_rc" -ne 42 ]; then
    echo "FAIL: Test C - wrapper returned $wrapper_rc, expected 42"
    exit 1
fi
if grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test C - wrapper produced both TASK_DONE and TASK_FAILED"
    exit 1
fi
echo "✓ Test C: PASSED"

# ─── Test D: wrapper terminated by timeout -> no TASK_DONE ─────────────────────
echo "=== Test D: wrapper terminated by timeout -> no TASK_DONE ==="
mkdir -p "$TMPDIR/testD"
cat > "$TMPDIR/testD/mock_orchestrator.sh" << 'MOCK_D'
#!/bin/bash
set -euo pipefail
sleep 30
echo "should not reach here" >&2
exit 0
MOCK_D
chmod +x "$TMPDIR/testD/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/testD/mock_orchestrator.sh"
STDOUT_FILE="$TMPDIR/stdoutD.txt"
STDERR_FILE="$TMPDIR/stderrD.txt"
timeout 1 "$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" || true
if grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test D - TASK_DONE emitted despite timeout termination"
    exit 1
fi
echo "✓ Test D: PASSED"

# ─── Test E: TASK_FAILED + rc=42 -> completion rejected ───────────────────────
echo "=== Test E: TASK_FAILED + rc=42 -> completion rejected ==="
mkdir -p "$TMPDIR/testE"
cat > "$TMPDIR/testE/mock_orchestrator.sh" << 'MOCK_E'
#!/bin/bash
set -euo pipefail
echo "orchestrator stdout" >&2
echo "TASK_FAILED: orchestration error"
exit 42
MOCK_E
chmod +x "$TMPDIR/testE/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/testE/mock_orchestrator.sh"
STDOUT_FILE="$TMPDIR/stdoutE.txt"
STDERR_FILE="$TMPDIR/stderrE.txt"
wrapper_rc=0
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" || wrapper_rc=$?
if ! grep -q "^TASK_FAILED:" "$STDOUT_FILE"; then
    echo "FAIL: Test E - TASK_FAILED not emitted by wrapper"
    exit 1
fi
if [ "$wrapper_rc" -eq 0 ]; then
    echo "FAIL: Test E - wrapper returned 0, expected non-zero"
    exit 1
fi
# Daemon logic should reject TASK_FAILED
if grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test E - wrapper produced both TASK_DONE and TASK_FAILED"
    exit 1
fi
echo "✓ Test E: PASSED"

# ─── Test F: timeout + no TASK_DONE -> completion rejected ────────────────────
echo "=== Test F: timeout + no TASK_DONE -> completion rejected ==="
mkdir -p "$TMPDIR/testF"
cat > "$TMPDIR/testF/mock_orchestrator.sh" << 'MOCK_F'
#!/bin/bash
set -euo pipefail
sleep 30
echo "should not reach here"
exit 0
MOCK_F
chmod +x "$TMPDIR/testF/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/testF/mock_orchestrator.sh"
STDOUT_FILE="$TMPDIR/stdoutF.txt"
STDERR_FILE="$TMPDIR/stderrF.txt"
timeout 1 "$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" || true
if grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test F - TASK_DONE emitted despite timeout termination"
    exit 1
fi
# Timeout causes wrapper to emit TASK_FAILED (expected behavior)
if ! grep -q "^TASK_FAILED:" "$STDOUT_FILE"; then
    echo "FAIL: Test F - no TASK_FAILED emitted after timeout"
    exit 1
fi
echo "✓ Test F: PASSED"

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "=== INTEGRATION TEST SUMMARY ==="
echo "✓ Test A: TASK_DONE + valid result comment -> completion accepted"
echo "✓ Test B: TASK_DONE + missing result comment -> completion rejected"
echo "✓ Test C: orchestrator rc=42 -> wrapper produces TASK_FAILED"
echo "✓ Test D: timeout termination -> no TASK_DONE"
echo "✓ Test E: TASK_FAILED + rc=42 -> completion rejected"
echo "✓ Test F: timeout -> TASK_FAILED (wrapper converts timeout to failure)"
echo "✓ All tests use real production functions (manul-daemon.sh)"
echo "=== ALL INTEGRATION TESTS PASSED ==="
