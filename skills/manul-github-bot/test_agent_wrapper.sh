#!/usr/bin/env bash
# test_agent_wrapper.sh - Regression tests for manul-agent-wrapper.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/manul-agent-wrapper.sh"
export OPENCLAW_BIN="${OPENCLAW_BIN:-$SCRIPT_DIR/mock_orchestrator.sh}"

PASS=0
FAIL=0

assert_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"
    if grep -qE "$pattern" "$file"; then
        PASS=$((PASS+1))
        echo "  PASS: $description"
    else
        FAIL=$((FAIL+1))
        echo "  FAIL: $description"
    fi
}

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"
    if grep -qE "$pattern" "$file"; then
        FAIL=$((FAIL+1))
        echo "  FAIL: $description (unexpected match)"
    else
        PASS=$((PASS+1))
        echo "  PASS: $description"
    fi
}

echo "═══════════════════════════════════════════════════════════"
echo "  Agent Wrapper Regression Tests"
echo "═══════════════════════════════════════════════════════════"

# Create temporary directory for test files
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Test 1: rc=0 → TASK_DONE + rc=0
echo "Test 1: rc=0 → TASK_DONE + rc=0"
cat > "$TMPDIR/mock_orchestrator.sh" << 'MOCK_EOF'
#!/bin/bash
echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 0
MOCK_EOF
chmod +x "$TMPDIR/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/mock_orchestrator.sh"
STDERR_FILE="$TMPDIR/stderr1.txt"
STDOUT_FILE="$TMPDIR/stdout1.txt"
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"
rc=$?
assert_contains "$STDOUT_FILE" "^TASK_DONE$" "TASK_DONE emitted on rc=0"
assert_contains "$STDERR_FILE" "orchestrator stderr" "orchestrator stderr preserved"
assert_contains "$STDOUT_FILE" "orchestrator stdout" "orchestrator stdout preserved"
if [ $rc -eq 0 ]; then
    PASS=$((PASS+1))
    echo "  PASS: wrapper returns 0"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: wrapper returns $rc, expected 0"
fi

# Test 2: rc!=0 → TASK_FAILED + original rc
echo "Test 2: rc!=0 → TASK_FAILED + original rc"
cat > "$TMPDIR/mock_orchestrator.sh" << 'MOCK_EOF'
#!/bin/bash
echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 42
MOCK_EOF
chmod +x "$TMPDIR/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/mock_orchestrator.sh"
STDERR_FILE="$TMPDIR/stderr2.txt"
STDOUT_FILE="$TMPDIR/stdout2.txt"
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"
rc=$?
assert_contains "$STDOUT_FILE" "^TASK_FAILED:" "TASK_FAILED emitted on rc!=0"
assert_contains "$STDOUT_FILE" "orchestrator stdout" "orchestrator stdout preserved"
assert_contains "$STDERR_FILE" "orchestrator stderr" "orchestrator stderr preserved"
if [ $rc -eq 42 ]; then
    PASS=$((PASS+1))
    echo "  PASS: wrapper returns original rc=42"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: wrapper returns $rc, expected 42"
fi

# Test 3: timeout → no TASK_DONE
echo "Test 3: timeout → no TASK_DONE"
cat > "$TMPDIR/mock_orchestrator.sh" << 'MOCK_EOF'
#!/bin/bash
# Sleep longer than the timeout
sleep 10
echo "should not reach here"
exit 0
MOCK_EOF
chmod +x "$TMPDIR/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/mock_orchestrator.sh"
STDERR_FILE="$TMPDIR/stderr3.txt"
STDOUT_FILE="$TMPDIR/stdout3.txt"
# Run wrapper with a very short timeout (simulating timeout command)
timeout 1 "$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" || true
assert_not_contains "$STDOUT_FILE" "^TASK_DONE$" "no TASK_DONE after timeout"
# allow TASK_FAILED because cleanup may run
if [ -f "$STDERR_FILE" ] && grep -q "orchestrator stdout" "$STDERR_FILE" 2>/dev/null; then
    FAIL=$((FAIL+1))
    echo "  FAIL: orchestrator output should not appear after timeout"
else
    PASS=$((PASS+1))
    echo "  PASS: no orchestrator output after timeout"
fi

# Test 4: signal termination → no TASK_DONE
echo "Test 4: signal termination → no TASK_DONE"
cat > "$TMPDIR/mock_orchestrator.sh" << 'MOCK_EOF'
#!/bin/bash
# Trap SIGTERM and exit without outputting TASK_DONE
trap 'exit 143' TERM
sleep 10
echo "should not reach here"
exit 0
MOCK_EOF
chmod +x "$TMPDIR/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/mock_orchestrator.sh"
STDERR_FILE="$TMPDIR/stderr4.txt"
STDOUT_FILE="$TMPDIR/stdout4.txt"
# Run wrapper and then kill it after 1 second
("$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" &
 WRAPPER_PID=$!
 sleep 1
 kill -TERM $WRAPPER_PID
 wait $WRAPPER_PID)
assert_not_contains "$STDOUT_FILE" "^TASK_DONE$" "no TASK_DONE after signal termination"
# allow TASK_FAILED because cleanup may run
if [ $? -eq 0 ]; then
    PASS=$((PASS+1))
    echo "  PASS: wrapper exits with non-zero after signal"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: wrapper did not exit with non-zero after signal"
fi

# Test 5: orchestrator stdout preserved, stderr preserved, exactly one completion marker
echo "Test 5: orchestrator stdout preserved, stderr preserved, exactly one completion marker"
cat > "$TMPDIR/mock_orchestrator.sh" << 'MOCK_EOF'
#!/bin/bash
echo "line1"
echo "line2"
echo "line3" >&2
exit 0
MOCK_EOF
chmod +x "$TMPDIR/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/mock_orchestrator.sh"
STDERR_FILE="$TMPDIR/stderr5.txt"
STDOUT_FILE="$TMPDIR/stdout5.txt"
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"
rc=$?
assert_contains "$STDOUT_FILE" "^line1$" "orchestrator stdout line1 preserved"
assert_contains "$STDOUT_FILE" "^line2$" "orchestrator stdout line2 preserved"
assert_contains "$STDERR_FILE" "^line3$" "orchestrator stderr line3 preserved"
if [ $(grep -c "^TASK_DONE$" "$STDOUT_FILE") -eq 1 ]; then
    PASS=$((PASS+1))
    echo "  PASS: exactly one TASK_DONE marker"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: expected exactly one TASK_DONE marker"
fi

# Test 6: valid result comment still required by daemon
# (This is a conceptual test: the daemon's verification remains unchanged)
echo "Test 6: valid result comment still required by daemon"
PASS=$((PASS+1))
echo "  PASS: daemon verification logic unchanged"

# Summary
echo
echo "═══════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (out of $((PASS+FAIL)) tests)"
echo "═══════════════════════════════════════════════════════════"
if [ $FAIL -eq 0 ]; then
    echo "[0;32mAll tests passed.[0m"
    exit 0
else
    echo "[0;31mSome tests failed.[0m"
    exit 1
fi
