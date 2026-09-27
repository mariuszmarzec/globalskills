#!/usr/bin/env bash
# test_agent_execution_smoke.sh — production executor-boundary smoke test.
#
# Exercises the real task-dispatch execution path used by manul-daemon.sh:
#
#   daemon -> setsid -> agent-task-runner -> controller -> executor
#          -> OpenClawAdapter -> ProcessRunner -> fake openclaw
#
# GitHub, OpenClaw gateway state, and the production ~/.manul runtime are never
# touched. Only the external agent executable is replaced with a fake binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d /tmp/manul-exec-smoke-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MANUL_DIR="$TEST_ROOT/manul"
CONFIG="$MANUL_DIR/config.json"
DB="$MANUL_DIR/state/manul.db"
LOG="$MANUL_DIR/logs/daemon.log"
LIFECYCLE_LOG="$MANUL_DIR/logs/lifecycle.log"
PID_FILE="$MANUL_DIR/state/locks/daemon.pid"
mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/logs" "$MANUL_DIR/workspace"

cat >"$CONFIG" <<'JSON'
{
  "repositories": ["test/repo"],
  "autoCreatePr": false,
  "automation": {
    "agentRuntime": "openclaw",
    "maxConcurrentTasks": 1,
    "maxAttemptsBeforeFail": 3,
    "heartbeatInterval": 60,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900,
    "lockTtl": 1800,
    "agentTimeoutSeconds": 30
  },
  "retryConfig": {
    "delaySeconds": 1
  },
  "retention": {
    "listDays": 7,
    "historyDays": 14
  }
}
JSON

MANUL_DIR="$MANUL_DIR" DB="$DB" bash "$SCRIPT_DIR/manul-conversation.sh" init-schema >/dev/null

# Hermetic local git remote + source repository.
ORIGIN="$TEST_ROOT/origin.git"
SOURCE_REPO="$TEST_ROOT/source-repo"
WORKSPACE="$MANUL_DIR/workspace/smoke-ws"

git init --bare -q "$ORIGIN"
git init -q "$SOURCE_REPO"
git -C "$SOURCE_REPO" config user.email smoke@example.com
git -C "$SOURCE_REPO" config user.name smoke
printf 'initial\n' >"$SOURCE_REPO/README.md"
git -C "$SOURCE_REPO" add README.md
git -C "$SOURCE_REPO" commit -qm initial
git -C "$SOURCE_REPO" branch -M master
git -C "$SOURCE_REPO" remote add origin "$ORIGIN"
git -C "$SOURCE_REPO" push -q -u origin master
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/master
git clone -q "$ORIGIN" "$WORKSPACE"

# Isolated fake OpenClaw executable.
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

# Fake poll wakes the real daemon dispatcher. The task itself is already queued
# in SQLite, so poll only supplies its wake-up contract.
POLL="$MANUL_DIR/poll.sh"
cat >"$POLL" <<'POLL'
#!/usr/bin/env bash
printf '%s\n' 'MANUL_RESULT {"fire":true,"new":1,"pending":1}'
POLL
chmod +x "$POLL"

# The real daemon sources workspace-manager.sh during dispatch. This hermetic
# implementation preserves the production workspace ownership invariant.
cat >"$MANUL_DIR/workspace-manager.sh" <<'WS'
#!/usr/bin/env bash
WORKSPACES_DIR="$MANUL_WORKSPACE"

workspace_lease() {
  local task_id="$1"
  local safe_task
  safe_task="$(printf '%s' "$task_id" | sed "s/'/''/g")"
  sqlite3 "$DB" "UPDATE workspaces SET status='BUSY', currentTaskId='$safe_task', lastUsedAt=datetime('now') WHERE workspaceId='smoke-ws' AND status='IDLE';"
  sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE workspaceId='smoke-ws' AND status='BUSY' AND currentTaskId='$safe_task' LIMIT 1;"
}

workspace_get_path() {
  local task_id="$1"
  local safe_task
  safe_task="$(printf '%s' "$task_id" | sed "s/'/''/g")"
  sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='smoke-ws' AND status='BUSY' AND currentTaskId='$safe_task' LIMIT 1;"
}

workspace_release() {
  local ws_id="$1"
  local task_id="$2"
  local safe_ws
  local safe_task
  safe_ws="$(printf '%s' "$ws_id" | sed "s/'/''/g")"
  safe_task="$(printf '%s' "$task_id" | sed "s/'/''/g")"
  sqlite3 "$DB" "UPDATE workspaces SET status='IDLE', currentTaskId=NULL, lastUsedAt=datetime('now') WHERE workspaceId='$safe_ws' AND currentTaskId='$safe_task';"
}

workspace_init() {
  mkdir -p "$WORKSPACES_DIR"
}
WS

sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS workspaces (
  workspaceId TEXT PRIMARY KEY,
  workspacePath TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'IDLE',
  currentTaskId TEXT,
  lastUsedAt TEXT
);"
sqlite3 "$DB" "DELETE FROM workspaces;"
sqlite3 "$DB" "INSERT INTO workspaces(workspaceId,workspacePath,status,lastUsedAt) VALUES('smoke-ws','$WORKSPACE','IDLE',datetime('now'));"

sqlite3 "$DB" "
INSERT INTO processed_comments(
  commentId, repository, issueNumber, commentUrl, author, agent, prompt, context,
  status, attempts, createdAt, conversationId, action
) VALUES (
  'smoke-execution-1',
  'test/repo',
  1,
  'https://github.com/test/repo/issues/1#issuecomment-1',
  'smoke',
  'main',
  'Run the execution-boundary smoke test.',
  '',
  'queued',
  0,
  datetime('now'),
  'conv-smoke',
  'IMPLEMENT'
);
"

export MANUL_DIR DB CONFIG LOG LIFECYCLE_LOG PID_FILE
export MANUL_TESTING=true
export AGENT_RUNTIME=openclaw
export OPENCLAW_BIN="$FAKE_BIN/openclaw"
export SMOKE_PROOF_FILE="$PROOF_FILE"
export MANUL_INTERVAL=1
export MANUL_POLL_TIMEOUT=10
export PATH="$FAKE_BIN:$PATH"

source "$SCRIPT_DIR/manul-daemon.sh"

# Keep external control-plane behavior hermetic while retaining the real
# dispatch, workspace validation, execution boundary and result transport.
ensure_workspace_pool() { return 0; }
ensure_repo() { printf '%s\n' "$SOURCE_REPO"; }
verify_repo() { return 0; }
acquire_repo_lock() { return 0; }
release_repo_lock() { return 0; }
revalidate_source() { return 0; }
start_heartbeat() { return 0; }
stop_heartbeat() { return 0; }
refresh_heartbeat() { return 0; }
acquire_task_lock() { return 0; }
release_task_lock() { return 0; }
post_github_comment() { return 0; }
archive_task_artifacts() { return 0; }

SMOKE_EVALUATED_RC=""
SMOKE_EVALUATED_STDOUT=""
SMOKE_STDOUT_CAPTURE="$TEST_ROOT/evaluated.stdout"
evaluate_task_completion() {
  local rc="$6"
  local stdout_file="$7"
  SMOKE_EVALUATED_RC="$rc"
  SMOKE_EVALUATED_STDOUT="$stdout_file"
  cp "$stdout_file" "$SMOKE_STDOUT_CAPTURE"

  if [ "$rc" -eq 0 ] && [ -f "$stdout_file" ] && grep -q '^TASK_DONE' "$stdout_file"; then
    COMPLETION_SUCCESS=true
    FINAL_COMMENT="Smoke test completed."
    FAIL_REASON=""
  else
    COMPLETION_SUCCESS=false
    FINAL_COMMENT="Smoke test failed."
    FAIL_REASON="Execution boundary did not produce TASK_DONE (rc=$rc)"
  fi
  return 0
}

# Guard the exact production wiring: the daemon must invoke the isolated
# runner, not an adapter directly.
if ! grep -q 'setsid --wait "$DAEMON_SCRIPT_DIR/agent-task-runner.sh"' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon does not use agent-task-runner process boundary" >&2
  exit 1
fi
if grep -q 'openclaw-adapter.sh' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon contains a direct OpenClaw adapter invocation" >&2
  exit 1
fi

run_once

if [ ! -s "$PROOF_FILE" ]; then
  echo "FAIL: fake OpenClaw was never invoked" >&2
  exit 1
fi
grep -q '^called$' "$PROOF_FILE" || { echo "FAIL: fake OpenClaw proof missing call marker" >&2; exit 1; }
grep -q -- 'agent' "$PROOF_FILE" || { echo "FAIL: adapter did not invoke OpenClaw agent command" >&2; exit 1; }
grep -q -- '--agent main' "$PROOF_FILE" || { echo "FAIL: adapter lost main agent selection" >&2; exit 1; }
grep -q 'task_id=smoke-execution-1' "$PROOF_FILE" || { echo "FAIL: task ID did not reach OpenClaw" >&2; exit 1; }
grep -q "workspace=$WORKSPACE" "$PROOF_FILE" || { echo "FAIL: workspace did not reach OpenClaw" >&2; exit 1; }

if [ "$SMOKE_EVALUATED_RC" -ne 0 ]; then
  echo "FAIL: daemon observed executor rc=$SMOKE_EVALUATED_RC" >&2
  exit 1
fi
if [ ! -f "$SMOKE_STDOUT_CAPTURE" ]; then
  echo "FAIL: daemon did not produce the task stdout artifact" >&2
  exit 1
fi
grep -q '^TASK_DONE smoke-agent-completed$' "$SMOKE_STDOUT_CAPTURE" || {
  echo "FAIL: TASK_DONE did not survive runner -> controller -> executor -> adapter -> ProcessRunner" >&2
  exit 1
}

grep -q 'agent executor summary for task smoke-execution-1: smoke-agent-completed' "$LOG" || {
  echo "FAIL: daemon did not consume the controller/executor result" >&2
  exit 1
}

if [ -f "$MANUL_DIR/smoke-execution-1.executor.pid" ]; then
  echo "FAIL: daemon leaked task executor PID file" >&2
  exit 1
fi

echo "PASS: daemon -> agent-task-runner -> controller -> executor -> OpenClawAdapter -> ProcessRunner -> fake OpenClaw"
echo "PASS: task metadata and TASK_DONE crossed the complete execution boundary"
echo "PASS: daemon has no direct adapter bypass"
