#!/usr/bin/env bash
# Regression tests for the separate Todo Desktop and Fiteo MCP source adapters.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "\${BASH_SOURCE[0]:-$0}")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/manul-todo-sources-XXXXXX)"
BIN="$TEST_DIR/bin"
mkdir -p "$BIN"
trap 'rm -rf "$TEST_DIR"' EXIT
PYTHON_BIN="$(command -v python3)"

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_contains() { [[ "$2" == *"$3"* ]] && ok "$1" || fail "$1"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && ok "$1" || fail "$1"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (expected '$2', got '$3')"; }
assert_rc() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (expected rc=$2, got rc=$3)"; }

cat > "$BIN/python3" <<'PYTHON'
#!/usr/bin/env bash
set -uo pipefail
tool=""
arguments="{}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool) tool="$2"; shift 2 ;;
    --arguments) arguments="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$tool" in
  list_tasks|todo_list_tasks)
    cat "$TODO_MCP_FIXTURE"
    ;;
  mark_tasks_done|todo_mark_tasks|todo_update_task)
    printf '%s\t%s\n' "$tool" "$arguments" >> "$TODO_MCP_CALL_LOG"
    printf '{"success":true}\n'
    ;;
  *)
    echo "unexpected fake MCP tool: $tool" >&2
    exit 2
    ;;
esac
PYTHON
chmod +x "$BIN/python3"
export PATH="$BIN:$PATH"
export TODO_LOCAL_MCP_TOKEN="local-test-token"
export FITEO_PAT="remote-test-token"
export TODO_MCP_CALL_LOG="$TEST_DIR/mcp-calls.log"
touch "$TODO_MCP_CALL_LOG"

source "$SCRIPT_DIR/task-source-todo-local.sh"
source "$SCRIPT_DIR/task-source-todo-remote.sh"

cat > "$TEST_DIR/local.json" <<'JSON'
[
  {
    "id": 1,
    "description": "/manul Implement local task",
    "addedTime": "2026-10-01T10:00:00",
    "modifiedTime": "2026-10-01T10:00:00",
    "parentTaskId": null,
    "subTasks": [
      {
        "id": 10,
        "description": "First step",
        "addedTime": "2026-10-01T10:01:00",
        "modifiedTime": "2026-10-01T10:01:00",
        "parentTaskId": 1,
        "subTasks": [
          {
            "id": 11,
            "description": "Nested step",
            "addedTime": "2026-10-01T10:02:00",
            "modifiedTime": "2026-10-01T10:02:00",
            "parentTaskId": 10,
            "subTasks": [],
            "isToDo": true,
            "priority": 3,
            "scheduler": null,
            "shares": []
          }
        ],
        "isToDo": true,
        "priority": 4,
        "scheduler": null,
        "shares": []
      },
      {
        "id": 12,
        "description": "Second step",
        "addedTime": "2026-10-01T10:03:00",
        "modifiedTime": "2026-10-01T10:03:00",
        "parentTaskId": 1,
        "subTasks": [],
        "isToDo": false,
        "priority": 9,
        "scheduler": null,
        "shares": []
      }
    ],
    "isToDo": true,
    "priority": 2,
    "scheduler": null,
    "shares": []
  },
  {
    "id": 2,
    "description": "No trigger",
    "addedTime": "2026-10-01T11:00:00",
    "modifiedTime": "2026-10-01T11:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": true,
    "priority": 1,
    "scheduler": null,
    "shares": []
  },
  {
    "id": 3,
    "description": "/manul Scheduled root",
    "addedTime": "2026-10-01T12:00:00",
    "modifiedTime": "2026-10-01T12:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": true,
    "priority": 1,
    "scheduler": {"type":"OneShot"},
    "shares": []
  },
  {
    "id": 4,
    "description": "/manul Already done",
    "addedTime": "2026-10-01T13:00:00",
    "modifiedTime": "2026-10-01T13:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": false,
    "priority": 1,
    "scheduler": null,
    "shares": []
  }
]
JSON

cat > "$TEST_DIR/remote.json" <<'JSON'
[
  {
    "id": 21,
    "ownerId": 4,
    "description": "Shared implementation",
    "addedTime": "2026-10-01T10:00:00",
    "modifiedTime": "2026-10-01T10:00:00",
    "parentTaskId": null,
    "subTasks": [
      {
        "id": 22,
        "ownerId": 4,
        "description": "Shared child step",
        "addedTime": "2026-10-01T10:01:00",
        "modifiedTime": "2026-10-01T10:01:00",
        "parentTaskId": 21,
        "subTasks": [
          {
            "id": 23,
            "ownerId": 4,
            "description": "Shared nested step",
            "addedTime": "2026-10-01T10:02:00",
            "modifiedTime": "2026-10-01T10:02:00",
            "parentTaskId": 22,
            "subTasks": [],
            "isToDo": true,
            "priority": 7,
            "scheduler": null,
            "shares": []
          }
        ],
        "isToDo": true,
        "priority": 8,
        "scheduler": null,
        "shares": []
      }
    ],
    "isToDo": true,
    "priority": 2,
    "scheduler": null,
    "shares": [
      {"userId":"77","permission":"EDITOR_AND_VIEWER"}
    ]
  },
  {
    "id": 24,
    "ownerId": 4,
    "description": "Viewer-only task",
    "addedTime": "2026-10-01T11:00:00",
    "modifiedTime": "2026-10-01T11:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": true,
    "priority": 1,
    "scheduler": null,
    "shares": [
      {"userId":"77","permission":"VIEWER"}
    ]
  },
  {
    "id": 25,
    "ownerId": 4,
    "description": "Not shared",
    "addedTime": "2026-10-01T12:00:00",
    "modifiedTime": "2026-10-01T12:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": true,
    "priority": 1,
    "scheduler": null,
    "shares": []
  }
]
JSON

LOCAL_SOURCE='{"type":"todo_local_mcp","repository":"owner/todo","tokenEnv":"TODO_LOCAL_MCP_TOKEN"}'
REMOTE_SOURCE='{"type":"todo_remote_mcp","repository":"owner/todo","tokenEnv":"FITEO_PAT","manulUserId":77,"url":"https://fiteo.example.test/mcp"}'

echo "=== Local Todo source ==="
export TODO_MCP_FIXTURE="$TEST_DIR/local.json"
local_tasks="$(task_source_todo_local_poll "$LOCAL_SOURCE")"
assert_eq "only local /manul root is enqueued" "1" "$(printf '%s\n' "$local_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
local_task="$(printf '%s\n' "$local_tasks" | jq -c '.')"
assert_contains "local root source type is normalized" "$local_task" '"taskSourceType":"todo_local_mcp"'
assert_contains "local task uses local bridge URL" "$(todo_source_local_config "$LOCAL_SOURCE")" 'http://127.0.0.1:8766/mcp'
local_prompt="$(jq -r '.prompt' <<<"$local_task")"
assert_contains "local prompt preserves first subtask before nested and sibling steps" "$local_prompt" '1. [TODO] First step'
assert_contains "nested step immediately follows its parent in the supplied tree order" "$local_prompt" '2. [TODO] Nested step'
assert_contains "later sibling remains after nested child" "$local_prompt" '3. [DONE] Second step'
assert_not_contains "local subtask is not enqueued as an independent root" "$local_tasks" '"taskSourceId":"10@'
assert_eq "local revalidation accepts unchanged task tree" "0" "$(
  task_source_todo_local_revalidate "$LOCAL_SOURCE" "$(jq -r '.taskSourceId' <<<"$local_task")"; echo $?
)"

local_fingerprint="$(todo_task_version_from_source_id "$(jq -r '.taskSourceId' <<<"$local_task")")"
jq '.[0].subTasks[0].description = "Externally changed step"' "$TEST_DIR/local.json" > "$TEST_DIR/local-changed.json"
export TODO_MCP_FIXTURE="$TEST_DIR/local-changed.json"
rc=0
task_source_todo_local_revalidate "$LOCAL_SOURCE" "$(jq -r '.taskSourceId' <<<"$local_task")" || rc=$?
assert_rc "local revalidation rejects a changed task tree" "1" "$rc"

export TODO_MCP_FIXTURE="$TEST_DIR/local.json"
: > "$TODO_MCP_CALL_LOG"
task_source_todo_local_complete "$LOCAL_SOURCE" "$(jq -r '.taskSourceId' <<<"$local_task")"
local_call="$(cat "$TODO_MCP_CALL_LOG")"
assert_contains "local completion uses local bulk mark tool" "$local_call" 'mark_tasks_done'
assert_contains "local completion includes root and all descendants" "$local_call" '"taskIds":[1,10,11,12]'

echo "=== Remote Fiteo source ==="
export TODO_MCP_FIXTURE="$TEST_DIR/remote.json"
remote_tasks="$(task_source_todo_remote_poll "$REMOTE_SOURCE")"
assert_eq "only explicitly editor-shared remote root is enqueued" "1" "$(printf '%s\n' "$remote_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
remote_task="$(printf '%s\n' "$remote_tasks" | jq -c '.')"
assert_contains "remote root source type is normalized" "$remote_task" '"taskSourceType":"todo_remote_mcp"'
assert_not_contains "viewer-only task is excluded" "$remote_tasks" '"taskSourceId":"24@'
assert_not_contains "unshared task is excluded" "$remote_tasks" '"taskSourceId":"25@'
remote_id="$(jq -r '.taskSourceId' <<<"$remote_task")"
assert_eq "remote revalidation accepts unchanged tree" "0" "$(
  task_source_todo_remote_revalidate "$REMOTE_SOURCE" "$remote_id"; echo $?
)"

# A completed child and changed modifiedTime must not invalidate a retry while
# the root remains active; the structural fingerprint deliberately ignores
# progress flags/timestamps but still detects topology/content changes.
jq '.[0].subTasks[0].isToDo = false | .[0].subTasks[0].modifiedTime = "2026-10-02T10:00:00"' \
  "$TEST_DIR/remote.json" > "$TEST_DIR/remote-progress.json"
export TODO_MCP_FIXTURE="$TEST_DIR/remote-progress.json"
assert_eq "partial subtask completion does not invalidate source identity" "0" "$(
  task_source_todo_remote_revalidate "$REMOTE_SOURCE" "$remote_id"; echo $?
)"

export TODO_MCP_FIXTURE="$TEST_DIR/remote.json"
: > "$TODO_MCP_CALL_LOG"
task_source_todo_remote_complete "$REMOTE_SOURCE" "$remote_id"
remote_calls="$(cat "$TODO_MCP_CALL_LOG")"
assert_eq "remote marks each descendant and root individually" "3" "$(printf '%s\n' "$remote_calls" | wc -l | tr -d ' ')"
assert_contains "remote completion uses Fiteo partial update tool" "$remote_calls" 'todo_update_task'
assert_contains "remote completion updates nested child before its parent" "$remote_calls" '"id":23'
first_remote_id="$(head -1 "$TODO_MCP_CALL_LOG" | cut -f2- | jq -r '.id')"
last_remote_id="$(tail -1 "$TODO_MCP_CALL_LOG" | cut -f2- | jq -r '.id')"
assert_eq "remote completion marks the root last for retry safety" "21" "$last_remote_id"
assert_eq "remote completion starts at deepest descendant" "23" "$first_remote_id"

echo
if "$PYTHON_BIN" "$SCRIPT_DIR/test_todo_mcp_client.py"; then
  ok "Streamable HTTP MCP client tests passed"
else
  fail "Streamable HTTP MCP client tests failed"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
