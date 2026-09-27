#!/usr/bin/env bash
# test_agent_execution_smoke.sh — production executor-boundary smoke test.
#
# Exercises the exact process boundary used by manul-daemon.sh:
#
#   daemon dispatch line
#     -> setsid
#     -> agent-task-runner
#     -> AgentExecutionController
#     -> AgentExecutor
#     -> OpenClawAdapter
#     -> ProcessRunner
#     -> fake OpenClaw executable
#
# GitHub, SQLite state, OpenClaw gateway state, and the production ~/.manul
# runtime are never touched. Control-plane scheduling is intentionally outside
# this test; the execution boundary itself is real.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d /tmp/manul-exec-smoke-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MANUL_DIR="$TEST_ROOT/manul"
mkdir -p "$MANUL_DIR/state/tasks" "$MANUL_DIR/state/locks" "$MANUL_DIR/logs"

cat >"$MANUL_DIR/config.json" <<'JSON'
{
  "automation": {
    "agentRuntime": "openclaw"
  }
}
JSON

WORKSPACE="$TEST_ROOT/workspace"
mkdir -p "$WORKSPACE"

PROMPT_FILE="$MANUL_DIR/state/tasks/smoke.prompt.md"
printf '%s\n' 'Execute the executor-boundary smoke test.' >"$PROMPT_FILE"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
PROOF_FILE="$TEST_ROOT/openclaw-proof"

cat >"$FAKE_BIN/openclaw" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >>"$SMOKE_PROOF_FILE"
printf 'args=%s\n' "$*" >>"$SMOKE_PROOF_FILE"
printf 'task_id=%s\n' "$(printenv MANUL_TASK_ID)" >>"$SMOKE_PROOF_FILE"
printf 'workspace=%s\n' "$(printenv WORKSPACE)" >>"$SMOKE_PROOF_FILE"
printf 'TASK_DONE smoke-agent-completed\n'
MOCK
chmod +x "$FAKE_BIN/openclaw"

CTX_FILE="$MANUL_DIR/state/tasks/smoke.ctx.json"
RESULT_FILE="$MANUL_DIR/state/tasks/smoke.executor-result"
STDOUT_FILE="$MANUL_DIR/state/tasks/smoke.stdout"
STDERR_FILE="$MANUL_DIR/state/tasks/smoke.stderr"
EXECUTOR_PID_FILE="$MANUL_DIR/smoke-execution-1.executor.pid"

jq -n \
  --arg taskId "smoke-execution-1" \
  --arg prompt "$PROMPT_FILE" \
  --arg workspace "$WORKSPACE" \
  --arg stdoutFile "$STDOUT_FILE" \
  --arg stderrFile "$STDERR_FILE" \
  '{
    taskId: $taskId,
    prompt: $prompt,
    workspace: $workspace,
    agent: "",
    attempt: 1,
    timeout: 30,
    session_id: "",
    stdout_file: $stdoutFile,
    stderr_file: $stderrFile
  }' >"$CTX_FILE"

export MANUL_DIR
export AGENT_RUNTIME=openclaw
export OPENCLAW_BIN="$FAKE_BIN/openclaw"
export SMOKE_PROOF_FILE="$PROOF_FILE"
export PATH="$FAKE_BIN:$PATH"

# This must stay byte-for-byte compatible with the executor invocation used by
# manul-daemon.sh. The daemon creates the same task-local PID/result files and
# removes them after this wait returns.
if ! grep -q 'setsid --wait "$DAEMON_SCRIPT_DIR/agent-task-runner.sh"' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon no longer invokes agent-task-runner through setsid" >&2
  exit 1
fi

set +e
setsid --wait "$SCRIPT_DIR/agent-task-runner.sh" \
  "$CTX_FILE" \
  "$EXECUTOR_PID_FILE" \
  >"$RESULT_FILE" \
  2>"$TEST_ROOT/launcher.stderr"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo "FAIL: production executor boundary returned rc=$RC" >&2
  echo "--- launcher stderr ---" >&2
  cat "$TEST_ROOT/launcher.stderr" >&2 || true
  echo "--- adapter stderr ---" >&2
  cat "$STDERR_FILE" >&2 || true
  echo "--- executor result ---" >&2
  cat "$RESULT_FILE" >&2 || true
  exit 1
fi

if [ ! -f "$EXECUTOR_PID_FILE" ]; then
  echo "FAIL: agent-task-runner did not publish its task-local PID" >&2
  exit 1
fi
rm -f "$EXECUTOR_PID_FILE"

if [ ! -s "$RESULT_FILE" ]; then
  echo "FAIL: agent-task-runner produced no controller result" >&2
  exit 1
fi

jq -e \
  --arg taskId "smoke-execution-1" \
  '.status == "COMPLETED" and .task_id == $taskId and .exit_code == 0 and (.summary | contains("smoke-agent-completed"))' \
  "$RESULT_FILE" >/dev/null || {
    echo "FAIL: controller/executor returned unexpected result:" >&2
    cat "$RESULT_FILE" >&2
    exit 1
  }

if [ ! -s "$PROOF_FILE" ]; then
  echo "FAIL: fake OpenClaw was never invoked" >&2
  exit 1
fi

grep -q '^called$' "$PROOF_FILE" || { echo "FAIL: fake OpenClaw call marker missing" >&2; exit 1; }
grep -q -- 'agent' "$PROOF_FILE" || { echo "FAIL: OpenClawAdapter did not invoke the agent command" >&2; exit 1; }
grep -q -- '--agent main' "$PROOF_FILE" || { echo "FAIL: OpenClawAdapter lost the default main agent" >&2; exit 1; }
grep -q 'task_id=smoke-execution-1' "$PROOF_FILE" || { echo "FAIL: task ID was not propagated to OpenClaw" >&2; exit 1; }
grep -q "workspace=$WORKSPACE" "$PROOF_FILE" || { echo "FAIL: workspace was not propagated to OpenClaw" >&2; exit 1; }

grep -q '^TASK_DONE smoke-agent-completed$' "$STDOUT_FILE" || {
  echo "FAIL: TASK_DONE was not preserved through ProcessRunner" >&2
  exit 1
}

if [ -s "$STDERR_FILE" ]; then
  if grep -qiE 'error|failed|permission denied|not found' "$STDERR_FILE"; then
    echo "FAIL: execution produced unexpected adapter stderr:" >&2
    cat "$STDERR_FILE" >&2
    exit 1
  fi
fi

echo "PASS: daemon dispatch -> agent-task-runner -> controller -> executor -> OpenClawAdapter -> ProcessRunner -> fake OpenClaw"
echo "PASS: execution result JSON, task metadata and TASK_DONE crossed the boundary"
echo "PASS: task-local executor PID was created and cleaned up"
