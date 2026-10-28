#!/usr/bin/env bash
# Hermetic contract tests for Codex CLI and Claude Code adapters.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
assert_json() {
  if jq -e "$2" "$1" >/dev/null; then ok "$3"; else no "$3"; cat "$1" >&2; fi
}
mkdir -p "$TMP/bin" "$TMP/workspace" "$TMP/runtime" "$TMP/logs"
printf 'Task prompt input\n' > "$TMP/prompt"

cat > "$TMP/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$MOCK_ARGS_FILE"
cat > "$MOCK_PROMPT_FILE"
printf '%s\n' '{"type":"thread.started","thread_id":"codex-test-session"}'
if [ "$MOCK_MODE" = "missing-marker" ]; then
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"finished without lifecycle marker"}}'
else
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"TASK_DONE codex-adapter-test"}}'
fi
printf '%s\n' '{"type":"turn.completed"}'
MOCK
chmod +x "$TMP/bin/codex"

cat > "$TMP/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$MOCK_ARGS_FILE"
cat > "$MOCK_PROMPT_FILE"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"claude-test-session"}'
if [ "$MOCK_MODE" = "missing-marker" ]; then
  printf '%s\n' '{"type":"result","subtype":"success","result":"finished without lifecycle marker","session_id":"claude-test-session","is_error":false}'
else
  printf '%s\n' '{"type":"result","subtype":"success","result":"TASK_DONE claude-code-adapter-test","session_id":"claude-test-session","is_error":false}'
fi
MOCK
chmod +x "$TMP/bin/claude"

run_adapter() {
  runtime="$1"
  mode="$2"
  adapter="$SCRIPT_DIR/$runtime-adapter.sh"
  if [ "$runtime" = "claude-code" ]; then adapter="$SCRIPT_DIR/claude-code-adapter.sh"; fi
  if [ "$runtime" = "codex" ]; then adapter="$SCRIPT_DIR/codex-adapter.sh"; fi
  output="$TMP/$runtime-$mode.result.json"
  stdout="$TMP/$runtime-$mode.stdout"
  stderr="$TMP/$runtime-$mode.stderr"
  args="$TMP/$runtime-$mode.args"
  received="$TMP/$runtime-$mode.prompt"
  set +e
  if [ "$runtime" = "codex" ]; then
    CODEX_BIN="$TMP/bin/codex" CODEX_MODEL="mock-model" MOCK_MODE="$mode" MOCK_ARGS_FILE="$args" MOCK_PROMPT_FILE="$received" \
      MANUL_DIR="$TMP/runtime" MANUL_TASK_LOG_DIR="$TMP/logs" AGENT_RUNTIME=codex \
      bash "$adapter" --task-id "$runtime-$mode" --prompt "$TMP/prompt" --workspace "$TMP/workspace" --attempt 1 --timeout 10 --session-id "" --stdout-file "$stdout" --stderr-file "$stderr" > "$output"
  else
    CLAUDE_BIN="$TMP/bin/claude" CLAUDE_MODEL="mock-model" MOCK_MODE="$mode" MOCK_ARGS_FILE="$args" MOCK_PROMPT_FILE="$received" \
      MANUL_DIR="$TMP/runtime" MANUL_TASK_LOG_DIR="$TMP/logs" AGENT_RUNTIME=claude-code \
      bash "$adapter" --task-id "$runtime-$mode" --prompt "$TMP/prompt" --workspace "$TMP/workspace" --attempt 1 --timeout 10 --session-id "" --stdout-file "$stdout" --stderr-file "$stderr" > "$output"
  fi
  rc=$?
  set -e
  if [ "$mode" = "missing-marker" ]; then
    [ "$rc" -ne 0 ] && jq -e '.status == "FAILED" and .diagnostics.cause == "MISSING_TASK_MARKER"' "$output" >/dev/null \
      && ok "$runtime rejects a clean exit without TASK_DONE" || no "$runtime missing-marker handling (rc=$rc)"
    return
  fi
  [ "$rc" -eq 0 ] || { no "$runtime adapter exits successfully (rc=$rc)"; cat "$output" >&2; return; }
  assert_json "$output" '.status == "COMPLETED" and .exit_code == 0' "$runtime maps TASK_DONE to COMPLETED"
  if [ "$runtime" = "codex" ]; then
    assert_json "$output" '.session_id == "codex-test-session" and .diagnostics.runtime == "codex"' "$runtime returns session ID and runtime diagnostics"
    grep -Fq -- '--json' "$args" && ok "Codex CLI is called in JSONL mode" || no "Codex JSONL flag missing"
    grep -Fq -- '--sandbox workspace-write' "$args" && ok "Codex uses workspace-write sandbox" || no "Codex sandbox not set"
    grep -Fq -- '--ask-for-approval never' "$args" && ok "Codex uses explicit noninteractive approval policy" || no "Codex approval policy missing"
    grep -Fq -- '--model mock-model' "$args" && ok "Codex forwards configured model" || no "Codex model missing"
  else
    assert_json "$output" '.session_id == "claude-test-session" and .diagnostics.runtime == "claude-code"' "$runtime returns session ID and runtime diagnostics"
    grep -Fq -- '--print' "$args" && ok "Claude Code uses noninteractive print mode" || no "Claude print flag missing"
    grep -Fq -- '--output-format stream-json' "$args" && ok "Claude Code emits stream-json events" || no "Claude stream-json flag missing"
    grep -Fq -- '--permission-mode acceptEdits' "$args" && ok "Claude Code uses an explicit non-bypass permission mode" || no "Claude permission mode missing"
    ! grep -Eq -- '--dangerously-skip-permissions|bypassPermissions' "$args" && ok "Claude Code adapter does not bypass permissions" || no "Claude permission bypass found"
  fi
  cmp -s "$TMP/prompt" "$received" && ok "$runtime receives the exact prompt via stdin" || no "$runtime prompt stdin mismatch"
  grep -Fq "TASK_DONE $runtime-adapter-test" "$stdout" && ok "$runtime preserves the Manul completion marker" || no "$runtime lost TASK_DONE"
}

bash -n "$SCRIPT_DIR/codex-adapter.sh" && ok "Codex adapter syntax is valid" || no "Codex adapter syntax invalid"
bash -n "$SCRIPT_DIR/claude-code-adapter.sh" && ok "Claude Code adapter syntax is valid" || no "Claude Code adapter syntax invalid"
run_adapter codex success
run_adapter codex missing-marker
run_adapter claude-code success
run_adapter claude-code missing-marker

# Route through the production AgentExecutor, not only direct adapter calls.
for runtime in codex claude-code; do
  route_runtime="$TMP/route-$runtime"
  mkdir -p "$route_runtime"
  ctx="$TMP/route-$runtime.context.json"
  route_result="$TMP/route-$runtime.result.json"
  route_stdout="$TMP/route-$runtime.stdout"
  route_stderr="$TMP/route-$runtime.stderr"
  jq -n --arg id "route-$runtime" --arg prompt "$TMP/prompt" --arg workspace "$TMP/workspace" --arg stdout "$route_stdout" --arg stderr "$route_stderr" \
    '{taskId:$id,prompt:$prompt,workspace:$workspace,workspaceRoot:$workspace,workdir:$workspace,agent:"main",attempt:1,timeout:10,session_id:"",stdout_file:$stdout,stderr_file:$stderr}' > "$ctx"
  set +e
  if [ "$runtime" = "codex" ]; then
    CODEX_BIN="$TMP/bin/codex" CODEX_MODEL="mock-model" MOCK_MODE="success" MOCK_ARGS_FILE="$TMP/route-codex.args" MOCK_PROMPT_FILE="$TMP/route-codex.prompt" MANUL_DIR="$route_runtime" AGENT_RUNTIME=codex \
      bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$ctx" > "$route_result"
  else
    CLAUDE_BIN="$TMP/bin/claude" CLAUDE_MODEL="mock-model" MOCK_MODE="success" MOCK_ARGS_FILE="$TMP/route-claude-code.args" MOCK_PROMPT_FILE="$TMP/route-claude-code.prompt" MANUL_DIR="$route_runtime" AGENT_RUNTIME=claude-code \
      bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$ctx" > "$route_result"
  fi
  route_rc=$?
  set -e
  [ "$route_rc" -eq 0 ] && jq -e '.status == "COMPLETED" and .exit_code == 0' "$route_result" >/dev/null \
    && ok "AgentExecutor dispatches tasks to $runtime" || no "AgentExecutor failed to dispatch $runtime (rc=$route_rc)"
done

# Exercise runtime validation via the shared production path resolver.
printf '%s\n' '{"automation":{"agentRuntime":"codex","roleRuntime":"claude-code"}}' > "$TMP/runtime/config.json"
selection="$(MANUL_DIR="$TMP/runtime" bash -c 'source "$1/manul-paths.sh"; printf "%s|%s" "$AGENT_RUNTIME" "$ROLE_RUNTIME"' _ "$SCRIPT_DIR")"
[ "$selection" = "codex|claude-code" ] && ok "manul-paths accepts Codex automatic and Claude role runtimes" || no "runtime selection returned $selection"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
