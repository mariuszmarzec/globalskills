#!/usr/bin/env bash
# Todo REST API task-source provider.
# Uses /manul in description to avoid executing every personal Todo item.
set -uo pipefail

task_source_todo_api_poll() {
  local source_json="$1" base_url token_env tasks_path auth_scheme trigger token_value tasks url
  base_url="$(jq -r ".baseUrl // env.MANUL_TODO_BASE_URL // empty" <<<"$source_json")"
  token_env="$(jq -r ".tokenEnv // \"MANUL_TODO_PAT\"" <<<"$source_json")"
  tasks_path="$(jq -r ".tasksPath // \"/todo/api/1/tasks\"" <<<"$source_json")"
  auth_scheme="$(jq -r ".authScheme // \"Bearer\"" <<<"$source_json")"
  trigger="$(jq -r ".trigger // \"/manul\"" <<<"$source_json")"
  [ -n "$base_url" ] || { echo "task-source: todo_api disabled: baseUrl missing" >&2; return 0; }
  token_value="${!token_env:-}"
  [ -n "$token_value" ] || { echo "task-source: todo_api disabled: $token_env missing" >&2; return 0; }
  url="${base_url%/}${tasks_path}"
  tasks="$(curl --fail --silent --show-error --connect-timeout "${MANUL_TODO_CONNECT_TIMEOUT:-10}" --max-time "${MANUL_TODO_TIMEOUT:-30}"
    -H "Authorization: ${auth_scheme} ${token_value}" -H "Accept: application/json" "$url" 2>/dev/null)" || {
      echo "task-source: todo_api request failed: $url" >&2; return 1; }
  jq -e "type == \"array\"" >/dev/null 2>&1 <<<"$tasks" || { echo "task-source: todo_api returned non-array payload" >&2; return 1; }
  jq -c --arg base "$base_url" --arg trigger "$trigger" '
    .[] | select((.description // "") | test("(^|\\r?\\n)[ \\t]*" + ($trigger | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\$&")) + "([ \\t\\r\\n]|$)"))
    | {taskSourceType:"todo_api", taskSourceId:(.id|tostring), taskSourceUrl:($base + "/todo/api/1/tasks/" + (.id|tostring)),
       title:(.description // ""), body:(.description // ""), createdAt:(.addedTime // ""), updatedAt:(.modifiedTime // .addedTime // ""),
       state:(if (.isToDo // true) then "OPEN" else "DONE" end),
       metadata:{ownerId:.ownerId, isToDo:(.isToDo // true), priority:(.priority // null), parentTaskId:(.parentTaskId // null), expirationDate:(.expirationDate // null)}, execution:{kind:"non_repository"}}' <<<"$tasks"
}
