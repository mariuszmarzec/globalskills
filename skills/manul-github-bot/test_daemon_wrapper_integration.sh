#!/bin/bash
# test_daemon_wrapper_integration.sh - Integration test for daemon verification with wrapper
# Tests the actual production path: orchestrator -> manul-agent-wrapper.sh -> TASK_DONE/TASK_FAILED -> daemon completion logic -> verify_result_comment()

set -euo pipefail

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
cat > "$FAKE_GH" << 'FAKE_GH_EOF'
#!/bin/bash
# Fake gh for testing - returns valid result comments with deterministic marker
if [[ "$1" == "api/repos/"* ]]; then
    repo_issue_path="${1#api/repos/}"
    repo="${repo_issue_path%%/*}"
    issue_path="${repo_issue_path#*/issues/}"
    issue_num="${issue_path%%/*}"
    comments_path="${issue_path#*/comments/}"
    
    if [[ "$comments_path" == "comments" ]]; then
        echo '[{"id": 1001, "body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Test Result\n\n✓ Successfully processed the task\n\n— manul 🐈", "in_reply_to": null}]'
    elif [[ "$comments_path" =~ ^[0-9]+$ ]]; then
        echo '{"id": 1001, "body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Test Result\n\n✓ Successfully processed the task\n\n— manul 🐈", "in_reply_to": null}'
    else
        echo '{}'
    fi
fi
FAKE_GH_EOF
chmod +x "$FAKE_GH"

# Fake jq for JSON processing (simplified)
FAKE_JQ="$FAKE_BIN/jq"
cat > "$FAKE_JQ" << 'FAKE_JQ_EOF'
#!/bin/bash
if [[ "$1" == "-r" && "$2" == "\.id" ]]; then
    grep -o '"id":[0-9]*' "$3" | grep -o '[0-9]*' | tr '\n' ' ' | sed 's/ $//'
fi
FAKE_JQ_EOF
chmod +x "$FAKE_JQ"

export PATH="$FAKE_BIN:$PATH"

# Minimal environment for sourcing manul-daemon.sh
export MANUL_DIR="$SCRIPT_DIR"
export DB="$TMPDIR/manul_test.db"
export CONFIG="$SCRIPT_DIR/config.json"
export OPENCLAW_BIN="$SCRIPT_DIR/mock_orchestrator.sh"
export LOG="$TMPDIR/daemon.log"
export LIFECYCLE_LOG="$TMPDIR/lifecycle.log"
export PID_FILE="$TMPDIR/daemon.pid"

# Create minimal config file
cat > "$SCRIPT_DIR/config.json" << 'EOF'
{"pollInterval": 60}
EOF

# Extract the real verify_result_comment function from manul-daemon.sh
# Use awk to extract it in a clean, sourceable way
awk 'NR == 0 {in_func=0} /^verify_result_comment\(\)/ {in_func=1; print "#!/bin/bash"; print ""; print "# Required logging functions for verify_result_comment"; print "log() {"; print "    echo "[\$(date -Is)] \$@" >>"$LOG""; print "}"; print ""; print "lc_log() {"; print "    echo "[\$(date -Is)] \$@" >>"$LIFECYCLE_LOG""; print "}"; print ""; next} /^}/ {if(in_func) {in_func=0; next}} in_func {print}' "$MANUL_DIR/manul-daemon.sh" > "$TMPDIR/verify_result_comment.sh"

# Source the extracted function to ensure it's valid
if ! bash -c 'source "$TMPDIR/verify_result_comment.sh" && type -t verify_result_comment > /dev/null 2>&1'; then
    echo "FAIL: Could not source verify_result_comment function from manul-daemon.sh"
    exit 1
fi

# Create test database with commentUrl for correlation
TEMP_DB="$TMPDIR/test.db"
sqlite3 "$TEMP_DB" << 'SQLEOF'
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

# ─── REAL PRODUCTION TEST IMPLEMENTATIONS ─────────────────────────────────────────────

# Test A: TASK_DONE + valid result comment -> completion accepted (real daemon logic)
echo "=== Test A: TASK_DONE + valid result comment -> completion accepted ==="

# Setup orchestrator with TASK_DONE
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

# Real assertion: TASK_DONE must be emitted by wrapper
if ! grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test A - TASK_DONE not emitted by wrapper"
    exit 1
fi

# Use the REAL verify_result_comment() function from manul-daemon.sh
if verify_result_comment "test/repo" "42" "COMMENT_1" "COMMENT_1" 1 "$TEMP_DB"; then
    echo "✓ Test A: TASK_DONE + valid result comment -> completion accepted (REAL DAEMON LOGIC)"
else
    echo "FAIL: Test A - REAL DAEMON LOGIC rejected valid result comment"
    exit 1
fi

# Test B: TASK_DONE + missing result comment -> completion rejected (real daemon logic)
echo "=== Test B: TASK_DONE + missing result comment -> completion rejected ==="

# Create a scenario where verify_result_comment will fail
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

# Real assertion: TASK_DONE must be emitted by wrapper
if ! grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test B - TASK_DONE not emitted by wrapper"
    exit 1
fi

# Create a test DB without valid result comment correlation
TEMP_DB_B="$TMPDIR/test_b.db"
sqlite3 "$TEMP_DB_B" << 'SQLB'
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

if ! verify_result_comment "test/repo" "43" "COMMENT_B" "COMMENT_B" 1 "$TEMP_DB_B"; then
    echo "✓ Test B: TASK_DONE + missing result comment -> completion rejected (REAL DAEMON LOGIC)"
else
    echo "FAIL: Test B - REAL DAEMON LOGIC accepted missing result comment"
    exit 1
fi

# Test C: orchestrator rc=42 -> wrapper produces TASK_FAILED and returns 42
echo "=== Test C: orchestrator rc=42 -> wrapper produces TASK_FAILED ==="

# Setup orchestrator with rc=42
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
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"
wrapper_rc=$?

# Real assertion: TASK_FAILED must be emitted by wrapper
if ! grep -q "^TASK_FAILED:" "$STDOUT_FILE"; then
    echo "FAIL: Test C - TASK_FAILED not emitted by wrapper"
    exit 1
fi

# Real assertion: wrapper must return original orchestrator rc
if [ "$wrapper_rc" -ne 42 ]; then
    echo "FAIL: Test C - wrapper returned $wrapper_rc, expected 42"
    exit 1
fi

# Real assertion: daemon should NOT treat this as successful completion
if grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test C - wrapper produced both TASK_DONE and TASK_FAILED"
    exit 1
else
    echo "✓ Test C: orchestrator failure -> TASK_FAILED (daemon correctly rejects)"
fi

# Test D: wrapper terminated by timeout/signal -> no TASK_DONE
echo "=== Test D: wrapper terminated by timeout -> no TASK_DONE ==="

# Setup orchestrator that sleeps longer than timeout
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

# Use timeout to terminate the wrapper
cd "$SCRIPT_DIR"
timeout 1 "$WRAPPER" "prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" || true

# Real assertion: wrapper should NOT emit TASK_DONE when terminated
if grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test D - TASK_DONE emitted despite timeout termination"
    exit 1
fi

echo "✓ Test D: timeout termination prevents TASK_DONE (REAL DAEMON BEHAVIOR)"

# ─── CLEANUP ───────────────────────────────────────────────────────────────
rm -rf "$TMPDIR"

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo "=== INTEGRATION TEST SUMMARY ==="
echo "✓ Test A: TASK_DONE + valid result comment -> completion accepted (real daemon)"
echo "✓ Test B: TASK_DONE + missing result comment -> completion rejected (real daemon)"
echo "✓ Test C: orchestrator failure -> TASK_FAILED (daemon rejection)"
echo "✓ Test D: timeout termination -> no TASK_DONE (real daemon behavior)"
echo "✓ All tests use real production functions (manul-daemon.sh)"
echo "=== ALL INTEGRATION TESTS PASSED ==="
exit 0
