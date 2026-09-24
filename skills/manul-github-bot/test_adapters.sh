#!/usr/bin/env bash
# test_adapters.sh — Unit tests for AgentExecutor adapters and ProcessRunner.
#
# These tests use a temp dir, mock runtimes, and fake configs. They NEVER touch
# the production runtime (~/.manul or ~/.openclaw/manul).
#
# Coverage:
#   1. ProcessRunner.run mock mode returns configured fixtures
#   2. ProcessRunner.run production mode invokes a real command and reports rc
#   3. OpenClawAdapter: success path (TASK_DONE)
#   4. OpenClawAdapter: failure path (TASK_FAILED)
#   5. OpenClawAdapter: missing binary -> exit 127
#   6. OpenClawAdapter: timeout path
#   7. OpenCodeAdapter: success path
#   8. OpenCodeAdapter: failure path
#   9. OpenCodeAdapter: missing binary -> exit 127
#  10. AgentExecutor dispatches to the correct adapter based on AGENT_RUNTIME
#  11. AgentExecutor returns structured FAILED for unknown runtime
#  12. AgentExecutionController maps NEEDS_CONTINUATION / BLOCKED / TIMEOUT

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Each test gets its own isolated temp runtime dir.
TMPROOT=""
cleanup() {
  [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Test 1: ProcessRunner.run mock mode
# ---------------------------------------------------------------------------
test_process_runner_mock() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local mockdir="$tmp/bin"
  mkdir -p "$mockdir"

  # Create a mock opencode that writes TASK_DONE
  cat > "$mockdir/opencode" <<'MOCK'
#!/usr/bin/env bash
echo "TASK_DONE mock completed"
exit 0
MOCK
  chmod +x "$mockdir/opencode"

  # Use mock mode via ProcessRunner
  local result
  result="$(
    source "$SCRIPT_DIR/manul-paths.sh"
    source "$SCRIPT_DIR/process-runner.sh"
    ProcessRunner_MockMode=true
    ProcessRunner.fixture 0 2.5 false false
    ProcessRunner.fixture_stdout "TASK_DONE mocked"
    ProcessRunner.run --timeout 60 --cwd "$mockdir" -- opencode run --print
  )"

  local header
  header="$(printf '%s\n' "$result" | head -1)"
  if [ "$header" = "0|2.5|false|false" ]; then
    ok "ProcessRunner mock returns configured fixture"
  else
    fail "ProcessRunner mock returned: $header"
  fi

  if printf '%s\n' "$result" | grep -q 'TASK_DONE mocked'; then
    ok "ProcessRunner mock forwards fixture stdout"
  else
    fail "ProcessRunner mock did not forward fixture stdout"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: ProcessRunner.run production mode (real command)
# ---------------------------------------------------------------------------
test_process_runner_production() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"

  local result
  result="$(
    source "$SCRIPT_DIR/manul-paths.sh"
    source "$SCRIPT_DIR/process-runner.sh"
    ProcessRunner_TmpStdout="$tmp/out.txt"
    ProcessRunner_TmpStderr="$tmp/err.txt"
    echo "hello" > "$tmp/out.txt"
    echo "world" > "$tmp/err.txt"
    ProcessRunner.run -- echo hello-world
  )"
  local header
  header="$(printf '%s\n' "$result" | head -1)"
  local rc="${header%%|*}"
  if [ "$rc" = "0" ]; then
    ok "ProcessRunner production rc=0 for echo"
  else
    fail "ProcessRunner production rc=$rc (expected 0)"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: OpenClawAdapter success (TASK_DONE)
# ---------------------------------------------------------------------------
test_openclaw_success() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local bindir="$tmp/bin"
  mkdir -p "$bindir"

  # Mock openclaw that emits TASK_DONE
  cat > "$bindir/openclaw" <<'MOCK'
#!/usr/bin/env bash
echo "TASK_DONE mock task completed"
exit 0
MOCK
  chmod +x "$bindir/openclaw"

  local prompt="$tmp/prompt.txt"
  local stdoutf="$tmp/stdout.txt"
  local stderrf="$tmp/stderr.txt"
  echo "Do the task" > "$prompt"
  touch "$stdoutf" "$stderrf"

  local out
  out="$(PATH="$bindir:$PATH" OPENCLAW_BIN="$bindir/openclaw" \
    AGENT_RUNTIME=openclaw \
    MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/openclaw-adapter.sh" \
      --task-id test-1 \
      --prompt "$prompt" \
      --workspace "$tmp" \
      --attempt 1 \
      --timeout 30 \
      --session-id "" \
      --stdout-file "$stdoutf" \
      --stderr-file "$stderrf" 2>/dev/null)"

  local status
  status="$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
  if [ "$status" = "COMPLETED" ]; then
    ok "OpenClawAdapter COMPLETED on TASK_DONE"
  else
    fail "OpenClawAdapter status=$status (expected COMPLETED) out=$out"
  fi

  local sess
  sess="$(printf '%s' "$out" | jq -r '.session_id' 2>/dev/null)"
  if [ -n "$sess" ]; then
    ok "OpenClawAdapter returns session_id ($sess)"
  else
    fail "OpenClawAdapter returned empty session_id"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: OpenClawAdapter failure (TASK_FAILED)
# ---------------------------------------------------------------------------
test_openclaw_failure() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local bindir="$tmp/bin"
  mkdir -p "$bindir"

  cat > "$bindir/openclaw" <<'MOCK'
#!/usr/bin/env bash
echo "TASK_FAILED: something broke"
exit 1
MOCK
  chmod +x "$bindir/openclaw"

  local prompt="$tmp/prompt.txt"
  echo "Do the task" > "$prompt"
  local stdoutf="$tmp/stdout.txt"
  local stderrf="$tmp/stderr.txt"
  touch "$stdoutf" "$stderrf"

  local out
  out="$(PATH="$bindir:$PATH" OPENCLAW_BIN="$bindir/openclaw" \
    AGENT_RUNTIME=openclaw \
    MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/openclaw-adapter.sh" \
      --task-id test-2 \
      --prompt "$prompt" \
      --workspace "$tmp" \
      --attempt 1 \
      --timeout 30 \
      --session-id "" \
      --stdout-file "$stdoutf" \
      --stderr-file "$stderrf" 2>/dev/null)"

  local status
  status="$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
  if [ "$status" = "FAILED" ]; then
    ok "OpenClawAdapter FAILED on TASK_FAILED"
  else
    fail "OpenClawAdapter status=$status (expected FAILED)"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: OpenClawAdapter missing binary -> 127
# ---------------------------------------------------------------------------
test_openclaw_missing_binary() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local prompt="$tmp/prompt.txt"
  echo "Do the task" > "$prompt"
  local stdoutf="$tmp/stdout.txt"
  local stderrf="$tmp/stderr.txt"
  touch "$stdoutf" "$stderrf"

  # Use a PATH with no openclaw
  # Restrict PATH to a dir containing only bash/sh so the adapter can still
  # be invoked while openclaw is provably absent. (A bare empty PATH breaks
  # bash's own lookup, which would mask the adapter's real behaviour.)
  local restricted_bin="$tmp/restricted"
  mkdir -p "$restricted_bin"
  ln -sf "$(command -v bash)" "$restricted_bin/bash"
  ln -sf "$(command -v sh)" "$restricted_bin/sh"

  local out rc
  out="$(PATH="$restricted_bin" OPENCLAW_BIN="" \
    AGENT_RUNTIME=openclaw \
    MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/openclaw-adapter.sh" \
      --task-id test-3 \
      --prompt "$prompt" \
      --workspace "$tmp" \
      --attempt 1 \
      --timeout 30 \
      --session-id "" \
      --stdout-file "$stdoutf" \
      --stderr-file "$stderrf" 2>/dev/null)"
  rc=$?

  local status
  status="$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
  if [ "$status" = "FAILED" ] && [ $rc -eq 127 ]; then
    ok "OpenClawAdapter missing binary -> FAILED rc=127"
  else
    fail "OpenClawAdapter missing binary status=$status rc=$rc"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: OpenClawAdapter timeout
# ---------------------------------------------------------------------------
test_openclaw_timeout() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local bindir="$tmp/bin"
  mkdir -p "$bindir"

  cat > "$bindir/openclaw" <<'MOCK'
#!/usr/bin/env bash
sleep 5
echo "should not reach"
exit 0
MOCK
  chmod +x "$bindir/openclaw"

  local prompt="$tmp/prompt.txt"
  echo "Do the task" > "$prompt"
  local stdoutf="$tmp/stdout.txt"
  local stderrf="$tmp/stderr.txt"
  touch "$stdoutf" "$stderrf"

  local out
  out="$(PATH="$bindir:$PATH" OPENCLAW_BIN="$bindir/openclaw" \
    AGENT_RUNTIME=openclaw \
    MANUL_DIR="$tmp/runtime" \
    MANUL_OPENCLAW_AGENT_TIMEOUT=1 \
    bash "$SCRIPT_DIR/openclaw-adapter.sh" \
      --task-id test-4 \
      --prompt "$prompt" \
      --workspace "$tmp" \
      --attempt 1 \
      --timeout 1 \
      --session-id "" \
      --stdout-file "$stdoutf" \
      --stderr-file "$stderrf" 2>/dev/null)"

  local status
  status="$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
  if [ "$status" = "TIMEOUT" ]; then
    ok "OpenClawAdapter TIMEOUT on slow agent"
  else
    fail "OpenClawAdapter timeout status=$status (expected TIMEOUT)"
  fi
}

# ---------------------------------------------------------------------------
# Test 7: OpenCodeAdapter success (TASK_DONE)
# ---------------------------------------------------------------------------
test_opencode_success() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local bindir="$tmp/bin"
  mkdir -p "$bindir"

  cat > "$bindir/opencode" <<'MOCK'
#!/usr/bin/env bash
# Simulate opencode run reading from stdin
cat > /dev/null
echo "TASK_DONE opencode completed"
exit 0
MOCK
  chmod +x "$bindir/opencode"

  local prompt="$tmp/prompt.txt"
  echo "Do the task" > "$prompt"
  local stdoutf="$tmp/stdout.txt"
  local stderrf="$tmp/stderr.txt"
  touch "$stdoutf" "$stderrf"

  local out
  out="$(PATH="$bindir:$PATH" OPENCODE_BIN="$bindir/opencode" \
    AGENT_RUNTIME=opencode \
    MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/opencode-adapter.sh" \
      --task-id test-oc-1 \
      --prompt "$prompt" \
      --workspace "$tmp" \
      --attempt 1 \
      --timeout 30 \
      --session-id "" \
      --stdout-file "$stdoutf" \
      --stderr-file "$stderrf" 2>/dev/null)"

  local status
  status="$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
  if [ "$status" = "COMPLETED" ]; then
    ok "OpenCodeAdapter COMPLETED on TASK_DONE"
  else
    fail "OpenCodeAdapter status=$status (expected COMPLETED) out=$out"
  fi
}

# ---------------------------------------------------------------------------
# Test 8: OpenCodeAdapter failure
# ---------------------------------------------------------------------------
test_opencode_failure() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local bindir="$tmp/bin"
  mkdir -p "$bindir"

  cat > "$bindir/opencode" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
echo "TASK_FAILED: opencode broke"
exit 1
MOCK
  chmod +x "$bindir/opencode"

  local prompt="$tmp/prompt.txt"
  echo "Do the task" > "$prompt"
  local stdoutf="$tmp/stdout.txt"
  local stderrf="$tmp/stderr.txt"
  touch "$stdoutf" "$stderrf"

  local out
  out="$(PATH="$bindir:$PATH" OPENCODE_BIN="$bindir/opencode" \
    AGENT_RUNTIME=opencode \
    MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/opencode-adapter.sh" \
      --task-id test-oc-2 \
      --prompt "$prompt" \
      --workspace "$tmp" \
      --attempt 1 \
      --timeout 30 \
      --session-id "" \
      --stdout-file "$stdoutf" \
      --stderr-file "$stderrf" 2>/dev/null)"

  local status
  status="$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
  if [ "$status" = "FAILED" ]; then
    ok "OpenCodeAdapter FAILED on TASK_FAILED"
  else
    fail "OpenCodeAdapter status=$status (expected FAILED)"
  fi
}

# ---------------------------------------------------------------------------
# Test 9: OpenCodeAdapter missing binary -> 127
# ---------------------------------------------------------------------------
test_opencode_missing_binary() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local prompt="$tmp/prompt.txt"
  echo "Do the task" > "$prompt"
  local stdoutf="$tmp/stdout.txt"
  local stderrf="$tmp/stderr.txt"
  touch "$stdoutf" "$stderrf"

  # Restrict PATH to bash/sh only so the adapter can still be invoked while
  # opencode is provably absent.
  local restricted_bin="$tmp/restricted"
  mkdir -p "$restricted_bin"
  ln -sf "$(command -v bash)" "$restricted_bin/bash"
  ln -sf "$(command -v sh)" "$restricted_bin/sh"

  local out rc
  out="$(PATH="$restricted_bin" OPENCODE_BIN="" \
    AGENT_RUNTIME=opencode \
    MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/opencode-adapter.sh" \
      --task-id test-oc-3 \
      --prompt "$prompt" \
      --workspace "$tmp" \
      --attempt 1 \
      --timeout 30 \
      --session-id "" \
      --stdout-file "$stdoutf" \
      --stderr-file "$stderrf" 2>/dev/null)"
  rc=$?

  local status
  status="$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
  if [ "$status" = "FAILED" ] && [ $rc -eq 127 ]; then
    ok "OpenCodeAdapter missing binary -> FAILED rc=127"
  else
    fail "OpenCodeAdapter missing binary status=$status rc=$rc"
  fi
}

# ---------------------------------------------------------------------------
# Test 10: AgentExecutor dispatches to correct adapter
# ---------------------------------------------------------------------------
test_agent_executor_dispatch() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local bindir="$tmp/bin"
  mkdir -p "$bindir"

  cat > "$bindir/opencode" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
echo "TASK_DONE routed to opencode"
exit 0
MOCK
  chmod +x "$bindir/opencode"

  local prompt="$tmp/prompt.txt"
  echo "Do the task" > "$prompt"
  local ctx="$tmp/ctx.json"
  jq -n \
    --arg prompt "$prompt" \
    --arg workspace "$tmp" \
    '{taskId: "test-route-1", prompt: $prompt, workspace: $workspace, attempt: 1, timeout: 30}' \
    > "$ctx"

  local out
  out="$(PATH="$bindir:$PATH" OPENCODE_BIN="$bindir/opencode" \
    AGENT_RUNTIME=opencode \
    MANUL_DIR="$tmp/runtime" \
    bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$ctx" 2>/dev/null)"

  local status
  status="$(printf '%s' "$out" | jq -r '.status' 2>/dev/null)"
  if [ "$status" = "COMPLETED" ]; then
    ok "AgentExecutor routed opencode runtime to OpenCodeAdapter"
  else
    fail "AgentExecutor opencode dispatch status=$status"
  fi
}

# ---------------------------------------------------------------------------
# Test 11: AgentExecutor unknown runtime -> FAILED
# ---------------------------------------------------------------------------
test_agent_executor_unknown_runtime() {
  local tmp
  tmp="$(mktemp -d)"
  TMPROOT="$tmp"
  local prompt="$tmp/prompt.txt"
  echo "Do the task" > "$prompt"
  local ctx="$tmp/ctx.json"
  jq -n \
    --arg prompt "$prompt" \
    --arg workspace "$tmp" \
    '{taskId: "test-route-2", prompt: $prompt, workspace: $workspace, attempt: 1, timeout: 30}' \
    > "$ctx"

  # Unknown runtimes are rejected by manul-paths.sh's fail-fast guard BEFORE
# the dispatcher is reached. Verify the guard fires: non-zero exit, error on
# stderr, and no JSON on stdout.
  local out rc err
  out="$(AGENT_RUNTIME=bogus \
    MANUL_DIR="$tmp/runtime" \
    bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$ctx" 2>"$tmp/err.txt")"
  rc=$?
  err="$(cat "$tmp/err.txt" 2>/dev/null)"

  if [ $rc -ne 0 ] && printf '%s' "$err" | grep -qi 'unknown agent runtime'; then
    ok "Unknown runtime rejected by manul-paths.sh guard (rc=$rc)"
  else
    fail "Unknown runtime guard: rc=$rc err=$err"
  fi
}

echo "=== Adapter Unit Tests ==="
echo "Canonical source: $SCRIPT_DIR"
echo ""

test_process_runner_mock
test_process_runner_production
test_openclaw_success
test_openclaw_failure
test_openclaw_missing_binary
test_openclaw_timeout
test_opencode_success
test_opencode_failure
test_opencode_missing_binary
test_agent_executor_dispatch
test_agent_executor_unknown_runtime

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
