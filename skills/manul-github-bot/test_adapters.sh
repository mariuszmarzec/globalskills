#!/usr/bin/env bash
# test_adapters.sh — isolated tests for Manul's runtime abstraction.
#
# These tests never use the production Manul runtime, OpenClaw state, OpenCode
# state, or GitHub. Runtime CLIs are fake executables in per-test temp dirs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

run_test() {
  local name="$1"
  shift
  echo
  echo "--- $name ---"
  "$@"
}

assert_json_status() {
  local json="$1" expected="$2" label="$3"
  local actual
  actual="$(printf '%s' "$json" | jq -r '.status // empty' 2>/dev/null || true)"
  if [ "$actual" = "$expected" ]; then
    ok "$label"
  else
    fail "$label (status=$actual output=$json)"
  fi
}

# ---------------------------------------------------------------------------
# 1. ProcessRunner mock
# ---------------------------------------------------------------------------
test_process_runner_mock() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local result
  result="$(
    MANUL_DIR="$tmp/runtime" \
    bash -c '
      source "$1/manul-paths.sh"
      source "$1/process-runner.sh"
      ProcessRunner_MockMode=true
      ProcessRunner.fixture 0 2.5 false false
      ProcessRunner.fixture_stdout "TASK_DONE mocked"
      ProcessRunner.run --timeout 60 --cwd "$2" -- fake run
    ' _ "$SCRIPT_DIR" "$tmp"
  )"

  local header
  header="$(printf '%s\n' "$result" | head -1)"
  [ "$header" = "0|2.5|false|false" ] \
    && ok "ProcessRunner mock returns configured fixture" \
    || fail "ProcessRunner mock returned: $header"
  printf '%s\n' "$result" | grep -q 'TASK_DONE mocked' \
    && ok "ProcessRunner mock forwards stdout" \
    || fail "ProcessRunner mock did not forward stdout"
}

# ---------------------------------------------------------------------------
# 2. ProcessRunner production cwd + env
# ---------------------------------------------------------------------------
test_process_runner_cwd_env() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/work"
  local result
  result="$(
    MANUL_DIR="$tmp/runtime" \
    bash -c '
      source "$1/manul-paths.sh"
      source "$1/process-runner.sh"
      ProcessRunner_TmpStdout="$2/out.txt"
      ProcessRunner_TmpStderr="$2/err.txt"
      ProcessRunner.run --cwd "$2/work" --env TEST_MANUL_VALUE=present -- sh -c '"'"'printf "%s\\n" "$PWD"; printf "%s\\n" "$TEST_MANUL_VALUE"'"'"'
    ' _ "$SCRIPT_DIR" "$tmp"
  )"
  local header
  header="$(printf '%s\n' "$result" | head -1)"
  if [ "${header%%|*}" = "0" ]; then
    ok "ProcessRunner production command succeeds"
  else
    fail "ProcessRunner production command rc=${header%%|*}"
  fi
  grep -Fxq "$tmp/work" "$tmp/out.txt" \
    && ok "ProcessRunner enforces --cwd" \
    || fail "ProcessRunner ignored --cwd"
  grep -Fxq "present" "$tmp/out.txt" \
    && ok "ProcessRunner enforces --env" \
    || fail "ProcessRunner ignored --env"
}

# ---------------------------------------------------------------------------
# 3. OpenClaw success + JSON escaping
# ---------------------------------------------------------------------------
test_openclaw_success() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"

  cat >"$tmp/bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'TASK_DONE completed "quoted" path'
exit 0
MOCK
  chmod +x "$tmp/bin/openclaw"
  printf '%s\n' "Do the task" >"$tmp/prompt"
  : >"$tmp/stdout"
  : >"$tmp/stderr"

  local out
  out="$(PATH="$tmp/bin:$PATH" OPENCLAW_BIN="$tmp/bin/openclaw" OPENCODE_BIN=/does/not/exist \
    AGENT_RUNTIME=openclaw MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/openclaw-adapter.sh" \
      --task-id oc-1 --prompt "$tmp/prompt" --workspace "$tmp" \
      --attempt 1 --timeout 30 --session-id "" \
      --stdout-file "$tmp/stdout" --stderr-file "$tmp/stderr" 2>/dev/null)"
  assert_json_status "$out" "COMPLETED" "OpenClawAdapter completes TASK_DONE"
  printf '%s' "$out" | jq empty >/dev/null 2>&1 \
    && ok "OpenClawAdapter always emits valid JSON" \
    || fail "OpenClawAdapter emitted invalid JSON"
  printf '%s' "$out" | jq -e '.summary | contains("quoted")' >/dev/null 2>&1 \
    && ok "OpenClawAdapter JSON-escapes summary" \
    || fail "OpenClawAdapter summary JSON escaping failed"
}

# ---------------------------------------------------------------------------
# 4. OpenClaw failure
# ---------------------------------------------------------------------------
test_openclaw_failure() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
echo "TASK_FAILED: broken"
exit 1
MOCK
  chmod +x "$tmp/bin/openclaw"
  echo "Do the task" >"$tmp/prompt"

  local out
  out="$(PATH="$tmp/bin:$PATH" OPENCLAW_BIN="$tmp/bin/openclaw" \
    AGENT_RUNTIME=openclaw MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/openclaw-adapter.sh" \
      --task-id oc-2 --prompt "$tmp/prompt" --workspace "$tmp" \
      --attempt 1 --timeout 30 --session-id "" \
      --stdout-file "$tmp/stdout" --stderr-file "$tmp/stderr" 2>/dev/null)"
  assert_json_status "$out" "FAILED" "OpenClawAdapter maps failure"
}

# ---------------------------------------------------------------------------
# 5. OpenClaw missing binary
# ---------------------------------------------------------------------------
test_openclaw_missing() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  echo "Do the task" >"$tmp/prompt"
  local out rc
  out="$(PATH="/usr/bin:/bin" OPENCLAW_BIN="" \
    AGENT_RUNTIME=openclaw MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/openclaw-adapter.sh" \
      --task-id oc-3 --prompt "$tmp/prompt" --workspace "$tmp" \
      --attempt 1 --timeout 30 --session-id "" \
      --stdout-file "$tmp/stdout" --stderr-file "$tmp/stderr" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 127 ] && ok "OpenClawAdapter missing binary rc=127" || fail "OpenClawAdapter missing binary rc=$rc"
}

# ---------------------------------------------------------------------------
# 6. OpenClaw timeout
# ---------------------------------------------------------------------------
test_openclaw_timeout() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
sleep 5
exit 0
MOCK
  chmod +x "$tmp/bin/openclaw"
  echo "Do the task" >"$tmp/prompt"

  local out
  out="$(PATH="$tmp/bin:$PATH" OPENCLAW_BIN="$tmp/bin/openclaw" \
    AGENT_RUNTIME=openclaw MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/openclaw-adapter.sh" \
      --task-id oc-4 --prompt "$tmp/prompt" --workspace "$tmp" \
      --attempt 1 --timeout 1 --session-id "" \
      --stdout-file "$tmp/stdout" --stderr-file "$tmp/stderr" 2>/dev/null)"
  assert_json_status "$out" "TIMEOUT" "OpenClawAdapter maps timeout"
}

# ---------------------------------------------------------------------------
# 7. OpenCode success — real CLI shape + text normalization
# ---------------------------------------------------------------------------
test_opencode_success() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MOCK_ARGS_FILE"
printf '%s\n' '{"type":"step_start","timestamp":1000,"sessionID":"ses_success","part":{"type":"step-start"}}'
printf '%s\n' '{"type":"text","timestamp":1100,"sessionID":"ses_success","part":{"type":"text","text":"TASK_DONE opencode completed"}}'
printf '%s\n' '{"type":"step_finish","timestamp":1200,"sessionID":"ses_success","part":{"type":"step-finish"}}'
exit 0
MOCK
  chmod +x "$tmp/bin/opencode"
  echo "Do the task" >"$tmp/prompt"
  : >"$tmp/stdout"
  : >"$tmp/stderr"

  local out
  out="$(PATH="$tmp/bin:$PATH" OPENCODE_BIN="$tmp/bin/opencode" OPENCLAW_BIN=/does/not/exist \
    MOCK_ARGS_FILE="$tmp/args" AGENT_RUNTIME=opencode MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/opencode-adapter.sh" \
      --task-id oc-1 --prompt "$tmp/prompt" --workspace "$tmp" \
      --agent build --attempt 1 --timeout 30 --session-id "" \
      --stdout-file "$tmp/stdout" --stderr-file "$tmp/stderr" 2>/dev/null)"
  assert_json_status "$out" "COMPLETED" "OpenCodeAdapter completes JSON-mode TASK_DONE"
  grep -q -- '--format json' "$tmp/args" && ok "OpenCodeAdapter requests JSON event format" || fail "OpenCodeAdapter did not request --format json"
  grep -q -- '--dir '"$tmp" "$tmp/args" && ok "OpenCodeAdapter passes workspace with --dir" || fail "OpenCodeAdapter did not pass --dir workspace"
  grep -q -- '--agent build' "$tmp/args" && ok "OpenCodeAdapter passes agent selection" || fail "OpenCodeAdapter ignored --agent"
  grep -q '^TASK_DONE opencode completed$' "$tmp/stdout" \
    && ok "OpenCodeAdapter normalizes text events to task output" \
    || fail "OpenCodeAdapter lost TASK_DONE marker"
  printf '%s' "$out" | jq -r '.session_id' | grep -qx 'ses_success' \
    && ok "OpenCodeAdapter returns runtime session ID" \
    || fail "OpenCodeAdapter did not return session ID"
}

# ---------------------------------------------------------------------------
# 8. OpenCode failure
# ---------------------------------------------------------------------------
test_opencode_failure() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '{"type":"error","timestamp":1000,"sessionID":"ses_fail","error":{"message":"provider failed"}}'
exit 1
MOCK
  chmod +x "$tmp/bin/opencode"
  echo "Do the task" >"$tmp/prompt"
  local out
  out="$(PATH="$tmp/bin:$PATH" OPENCODE_BIN="$tmp/bin/opencode" \
    AGENT_RUNTIME=opencode MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/opencode-adapter.sh" \
      --task-id oc-2 --prompt "$tmp/prompt" --workspace "$tmp" \
      --attempt 1 --timeout 30 --session-id "" \
      --stdout-file "$tmp/stdout" --stderr-file "$tmp/stderr" 2>/dev/null)"
  assert_json_status "$out" "FAILED" "OpenCodeAdapter maps non-step-limit failure"
}

# ---------------------------------------------------------------------------
# 9. OpenCode missing binary
# ---------------------------------------------------------------------------
test_opencode_missing() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  echo "Do the task" >"$tmp/prompt"
  local out rc
  out="$(PATH="/usr/bin:/bin" OPENCODE_BIN="" \
    AGENT_RUNTIME=opencode MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/opencode-adapter.sh" \
      --task-id oc-3 --prompt "$tmp/prompt" --workspace "$tmp" \
      --attempt 1 --timeout 30 --session-id "" \
      --stdout-file "$tmp/stdout" --stderr-file "$tmp/stderr" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 127 ] && ok "OpenCodeAdapter missing binary rc=127" || fail "OpenCodeAdapter missing binary rc=$rc"
}

# ---------------------------------------------------------------------------
# 10. OpenCode continuation reuses the exact same session
# ---------------------------------------------------------------------------
test_opencode_continuation() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_ARGS_FILE"
has_session=false
for arg in "$@"; do
  [ "$arg" = "--session" ] && has_session=true
done
if $has_session; then
  printf '%s\n' '{"type":"text","timestamp":2100,"sessionID":"ses_cont","part":{"type":"text","text":"TASK_DONE continued successfully"}}'
  exit 0
fi
printf '%s\n' '{"type":"step_start","timestamp":1000,"sessionID":"ses_cont","part":{"type":"step-start"}}'
printf '%s\n' '{"type":"error","timestamp":1500,"sessionID":"ses_cont","error":{"message":"maximum steps reached"}}'
exit 1
MOCK
  chmod +x "$tmp/bin/opencode"
  echo "Do the task" >"$tmp/prompt"

  local first rc1 sid
  first="$(PATH="$tmp/bin:$PATH" OPENCODE_BIN="$tmp/bin/opencode" \
    MOCK_ARGS_FILE="$tmp/args" AGENT_RUNTIME=opencode MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/opencode-adapter.sh" \
      --task-id cont-1 --prompt "$tmp/prompt" --workspace "$tmp" \
      --attempt 1 --timeout 30 --session-id "" \
      --stdout-file "$tmp/stdout1" --stderr-file "$tmp/stderr1" 2>/dev/null)"
  rc1=$?
  sid="$(printf '%s' "$first" | jq -r '.session_id')"
  assert_json_status "$first" "NEEDS_CONTINUATION" "OpenCodeAdapter detects step-limit continuation"
  [ "$rc1" -eq 1 ] && ok "OpenCodeAdapter continuation is retryable" || fail "OpenCodeAdapter continuation rc=$rc1"
  [ "$sid" = "ses_cont" ] && ok "OpenCodeAdapter exposes continuation session ID" || fail "Continuation session ID=$sid"

  local second
  second="$(PATH="$tmp/bin:$PATH" OPENCODE_BIN="$tmp/bin/opencode" \
    MOCK_ARGS_FILE="$tmp/args" AGENT_RUNTIME=opencode MANUL_DIR="$tmp/runtime" \
    bash "$SCRIPT_DIR/opencode-adapter.sh" \
      --task-id cont-1 --prompt "$tmp/prompt" --workspace "$tmp" \
      --attempt 2 --timeout 30 --session-id "$sid" \
      --stdout-file "$tmp/stdout2" --stderr-file "$tmp/stderr2" 2>/dev/null)"
  assert_json_status "$second" "COMPLETED" "OpenCodeAdapter resumes the same session"
  grep -q -- "--session $sid" "$tmp/args" \
    && ok "OpenCode continuation sends the persisted session ID" \
    || fail "OpenCode continuation did not reuse session ID"
  grep -q '^TASK_DONE continued successfully$' "$tmp/stdout2" \
    && ok "OpenCode continuation produces the completion marker" \
    || fail "OpenCode continuation lost TASK_DONE"
}

# ---------------------------------------------------------------------------
# 11. AgentExecutor dispatch
# ---------------------------------------------------------------------------
test_agent_executor_dispatch() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '{"type":"text","timestamp":1000,"sessionID":"ses_route","part":{"type":"text","text":"TASK_DONE routed"}}'
exit 0
MOCK
  chmod +x "$tmp/bin/opencode"
  echo "Do the task" >"$tmp/prompt"
  jq -n --arg p "$tmp/prompt" --arg w "$tmp" \
    '{taskId:"route-1",prompt:$p,workspace:$w,attempt:1,timeout:30}' >"$tmp/context.json"

  local out
  out="$(PATH="$tmp/bin:$PATH" OPENCODE_BIN="$tmp/bin/opencode" \
    AGENT_RUNTIME=opencode MANUL_DIR="$tmp/runtime" \
    bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$tmp/context.json" 2>/dev/null)"
  assert_json_status "$out" "COMPLETED" "AgentExecutor dispatches to OpenCodeAdapter"
}

# ---------------------------------------------------------------------------
# 12. Default/config runtime selection
# ---------------------------------------------------------------------------
test_runtime_selection() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/runtime"
  printf '%s\n' '{"automation":{"agentRuntime":"opencode"}}' >"$tmp/runtime/config.json"

  local runtime
  runtime="$(MANUL_DIR="$tmp/runtime" unset AGENT_RUNTIME MANUL_AGENT_RUNTIME; \
    MANUL_DIR="$tmp/runtime" bash -c 'source "$1/manul-paths.sh"; printf "%s" "$AGENT_RUNTIME"' _ "$SCRIPT_DIR")"
  [ "$runtime" = "opencode" ] \
    && ok "manul-paths reads automation.agentRuntime from config" \
    || fail "manul-paths ignored automation.agentRuntime (got $runtime)"

  runtime="$(MANUL_DIR="$tmp/other" AGENT_RUNTIME="" MANUL_AGENT_RUNTIME="" bash -c 'source "$1/manul-paths.sh"; printf "%s" "$AGENT_RUNTIME"' _ "$SCRIPT_DIR")"
  [ "$runtime" = "openclaw" ] \
    && ok "OpenClaw remains the default runtime" \
    || fail "Default runtime changed unexpectedly: $runtime"
}

# ---------------------------------------------------------------------------
# 13. Unknown runtime fails closed
# ---------------------------------------------------------------------------
test_unknown_runtime() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local rc err
  AGENT_RUNTIME=bogus MANUL_DIR="$tmp/runtime" \
    bash -c 'source "$1/agent-executor.sh"' _ "$SCRIPT_DIR" 2>"$tmp/err"
  rc=$?
  err="$(cat "$tmp/err" 2>/dev/null || true)"
  [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qi 'unknown agent runtime' \
    && ok "Unknown runtime is rejected before dispatch" \
    || fail "Unknown runtime guard rc=$rc err=$err"
}

# ---------------------------------------------------------------------------
# 14. Controller honors caller-supplied stdout path
# ---------------------------------------------------------------------------
test_controller_stdout_path() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
sleep 5
exit 0
MOCK
  chmod +x "$tmp/bin/opencode"
  echo "Do the task" >"$tmp/prompt"
  echo "TASK_DONE completed before controller timeout" >"$tmp/custom.stdout"
  jq -n --arg id "controller-1" --arg p "$tmp/prompt" --arg w "$tmp" \
    --arg out "$tmp/custom.stdout" --arg err "$tmp/custom.stderr" \
    '{taskId:$id,prompt:$p,workspace:$w,attempt:1,timeout:1,stdout_file:$out,stderr_file:$err}' >"$tmp/context.json"

  # Mock AgentExecutor at the shell-function boundary so the controller test
  # isolates the output-path logic.
  local out
  out="$(MANUL_DIR="$tmp/runtime" bash -c '
    source "$1/manul-paths.sh"
    source "$1/agent-execution-controller.sh"
    AgentExecutor.execute() {
      printf "%s\n" "{\"status\":\"TIMEOUT\",\"task_id\":\"controller-1\",\"exit_code\":124,\"summary\":\"timed out\",\"session_id\":\"ses_controller\",\"duration_s\":1}"
      return 124
    }
    AgentExecutionController.execute "$2"
  ' _ "$SCRIPT_DIR" "$tmp/context.json" 2>/dev/null)"
  assert_json_status "$out" "COMPLETED" "Controller checks the caller-supplied stdout file"
}

echo "=== Adapter Unit Tests ==="
echo "Canonical source: $SCRIPT_DIR"

test_process_runner_mock
test_process_runner_cwd_env
test_openclaw_success
test_openclaw_failure
test_openclaw_missing
test_openclaw_timeout
test_opencode_success
test_opencode_failure
test_opencode_missing
test_opencode_continuation
test_agent_executor_dispatch
test_runtime_selection
test_unknown_runtime
test_controller_stdout_path

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
