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
  if ! python3 - "$url" <<'PY_TODO_LOCAL_URL'
import ipaddress
import sys
from urllib.parse import urlsplit

try:
    parsed = urlsplit(sys.argv[1])
    host = parsed.hostname
    port = parsed.port
except ValueError:
    raise SystemExit(1)

if (
    parsed.scheme != "http"
    or host is None
    or parsed.path != "/mcp"
    or parsed.query
    or parsed.fragment
    or parsed.username is not None
    or parsed.password is not None
):
    raise SystemExit(1)

if host.casefold() == "localhost":
    raise SystemExit(0)

try:
    address = ipaddress.ip_address(host)
except ValueError:
    raise SystemExit(1)

if not address.is_loopback:
    raise SystemExit(1)
PY_TODO_LOCAL_URL
  then
    echo "task-source: local Todo MCP URL must use HTTP loopback (localhost, 127.0.0.0/8 or ::1) and the /mcp path" >&2
    return 2
  fi
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
    if todo_task_is_report_only "$task_json"; then
      if [ "$(jq -r '.allowReportOnly // false' <<<"$source_json")" != "true" ]; then
        echo "task-source: local Todo report-only task $task_id is disabled by allowReportOnly" >&2
        continue
      fi
      resolution='{"reportOnly":true}'
    else
      resolution="$(todo_task_resolve_repository "$source_json" "$task_json")" || {
        echo "task-source: local Todo task $task_id was not queued because its repository could not be resolved" >&2
        continue
      }
    fi
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
