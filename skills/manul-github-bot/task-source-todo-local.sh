#!/usr/bin/env bash
# Independent source adapter for Todo Desktop's local MCP endpoint.
set -uo pipefail

TODO_LOCAL_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$TODO_LOCAL_SOURCE_DIR/todo-task-source-utils.sh"

todo_source_local_config() {
  local source_json="$1" url
  source_json="$(jq -c '
    .url = (.url // "http://127.0.0.1:8766/mcp")
    | .tokenEnv = (.tokenEnv // "TODO_LOCAL_MCP_TOKEN")
  ' <<<"$source_json")" || return 2
  url="$(jq -r '.url // empty' <<<"$source_json")"
  [[ "$url" == http://127.0.0.1:8766/mcp ]] || {
    echo "task-source: local Todo MCP must use the existing WSL loopback bridge URL" >&2
    return 2
  }
  printf '%s\n' "$source_json"
}

task_source_todo_local_poll() {
  local source_json tasks_json task_json normalized resolution task_id
  source_json="$(todo_source_local_config "$1")"

  tasks_json="$(todo_mcp_source_list_tasks "$source_json" todo_local_mcp)" || return $?
  while IFS= read -r task_json; do
    [ -n "$task_json" ] || continue
    todo_task_is_active "$task_json" || continue
    todo_task_has_local_trigger "$task_json" || continue
    task_id="$(jq -r '.id // "unknown"' <<<"$task_json")"
    resolution="$(todo_task_resolve_repository "$source_json" "$task_json")" || {
      echo "task-source: local Todo task $task_id was not queued because its repository could not be resolved" >&2
      continue
    }
    normalized="$(todo_task_to_source_json "$task_json" todo_local_mcp "$resolution")" || continue
    printf '%s\n' "$normalized"
  done < <(
    jq -c '.[] | select(.parentTaskId == null) | select(.isToDo == true) | select(.scheduler == null)' <<<"$tasks_json"
  )
}

task_source_todo_local_revalidate() {
  local source_json="$1" source_id="$2"
  source_json="$(todo_source_local_config "$source_json")"
  todo_task_still_current "$source_json" todo_local_mcp "$source_id"
}

task_source_todo_local_complete() {
  local source_json="$1" source_id="$2"
  source_json="$(todo_source_local_config "$source_json")"
  todo_task_mark_done "$source_json" todo_local_mcp "$source_id"
}
