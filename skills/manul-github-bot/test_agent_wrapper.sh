#!/bin/bash
# test_agent_wrapper.sh - Regression tests for manul-agent-wrapper.sh
# Tests wrapper behavior: rc=0 -> TASK_DONE, rc!=0 -> TASK_FAILED

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/manul-agent-wrapper.sh"

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

# Test 1: rc=0 → TASK_DONE + rc=0
echo "Test 1: rc=0 → TASK_DONE + rc=0"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

MOCK_ORCHESTRATOR="$TMPDIR/mock_orchestrator.sh"
cat > "$MOCK_ORCHESTRATOR" << 'MOCK1'
#!/bin/bash
echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 0
MOCK1
chmod +x "$MOCK_ORCHESTRATOR"
export OPENCLAW_BIN="$MOCK_ORCHESTRATOR"

STDOUT_FILE="$TMPDIR/stdout1.txt"
STDERR_FILE="$TMPDIR/stderr1.txt"
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
MOCK_ORCHESTRATOR="$TMPDIR/mock_orchestrator.sh"
cat > "$MOCK_ORCHESTRATOR" << 'MOCK2'
#!/bin/bash
echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 42
MOCK2
chmod +x "$TMPDIR/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/mock_orchestrator.sh"

STDOUT_FILE="$TMPDIR/stdout2.txt"
STDERR_FILE="$TMPDIR/stderr2.txt"
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
MOCK_ORCHESTRATOR="$TMPDIR/mock_orchestrator.sh"
cat > "$MOCK_ORCHESTRATOR" << 'MOCK3'
#!/bin/bash
sleep 30
echo "should not reach here" >&2
exit 0
MOCK3
chmod +x "$TMPDIR/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/mock_orchestrator.sh"

STDOUT_FILE="$TMPDIR/stdout3.txt"
STDERR_FILE="$TMPDIR/stderr3.txt"
cd "$SCRIPT_DIR"
timeout 1 "$WRAPPER" "prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" || true
assert_not_contains "$STDOUT_FILE" "^TASK_DONE$" "no TASK_DONE after timeout"
if [ -f "$STDERR_FILE" ] && grep -q "orchestrator stdout" "$STDERR_FILE" 2>/dev/null; then
    FAIL=$((FAIL+1))
    echo "  FAIL: orchestrator output should not appear after timeout"
else
    PASS=$((PASS+1))
    echo "  PASS: no orchestrator output after timeout"
fi

# Test 4: signal termination → no TASK_DONE
echo "Test 4: signal termination → no TASK_DONE"
MOCK_ORCHESTRATOR="$TMPDIR/mock_orchestrator.sh"
cat > "$MOCK_ORCHESTRATOR" << 'MOCK4'
#!/bin/bash
sleep 30
echo "should not reach here" >&2
exit 0
MOCK4
chmod +x "$TMPDIR/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/mock_orchestrator.sh"

STDOUT_FILE="$TMPDIR/stdout4.txt"
STDERR_FILE="$TMPDIR/stderr4.txt"
(
    "$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" &
    WRAPPER_PID=$!
    sleep 1
    kill -TERM $WRAPPER_PID
    wait $WRAPPER_PID
)
wrapper_exit_code=$?
assert_not_contains "$STDOUT_FILE" "^TASK_DONE$" "no TASK_DONE after signal termination"
if [ $wrapper_exit_code -ne 0 ]; then
    PASS=$((PASS+1))
    echo "  PASS: wrapper exits with non-zero after signal"
else
    FAIL=$((FAIL+1))
    echo "  FAIL: wrapper did not exit with non-zero after signal"
fi

# Test 5: orchestrator stdout preserved, stderr preserved, exactly one completion marker
echo "Test 5: orchestrator stdout preserved, stderr preserved, exactly one completion marker"
MOCK_ORCHESTRATOR="$TMPDIR/mock_orchestrator.sh"
cat > "$MOCK_ORCHESTRATOR" << 'MOCK5'
#!/bin/bash
echo "line1"
echo "line2"
echo "line3" >&2
exit 0
MOCK5
chmod +x "$TMPDIR/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/mock_orchestrator.sh"

STDOUT_FILE="$TMPDIR/stdout5.txt"
STDERR_FILE="$TMPDIR/stderr5.txt"
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
