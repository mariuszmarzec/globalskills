#!/usr/bin/env bash
# Helpers shared by the independent local and remote Todo MCP source adapters.
# This is transport/normalization support, not a combined Todo adapter.

TODO_TASK_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

todo_mcp_source_url() {
  jq -r '.url // empty' <<<"$1"
}

todo_mcp_source_token_env() {
  jq -r '.tokenEnv // empty' <<<"$1"
}

todo_mcp_source_repository() {
  jq -r '.repository // empty' <<<"$1"
}

todo_mcp_source_call() {
  local source_json="$1" tool="$2" arguments="$3"
  local url token_env
  url="$(todo_mcp_source_url "$source_json")"
  token_env="$(todo_mcp_source_token_env "$source_json")"
  [ -n "$url" ] || {
    echo "todo-mcp: source URL is missing" >&2
    return 2
  }
  [ -n "$token_env" ] || {
    echo "todo-mcp: tokenEnv is missing" >&2
    return 2
  }
  python3 "$TODO_TASK_SOURCE_DIR/todo-mcp-client.py" \
    --url "$url" \
    --token-env "$token_env" \
    --tool "$tool" \
    --arguments "$arguments"
}

todo_mcp_source_list_tasks() {
  local source_json="$1" source_type="$2"
  case "$source_type" in
    todo_local_mcp)
      todo_mcp_source_call "$source_json" list_tasks '{}' ;;
    todo_remote_mcp)
      todo_mcp_source_call "$source_json" todo_list_tasks '{}' ;;
    *)
      echo "todo-mcp: unsupported source type: $source_type" >&2
      return 2 ;;
  esac
}

todo_task_id_from_source_id() {
  local source_id="$1"
  printf '%s' "${source_id%%@*}"
}

todo_task_version_from_source_id() {
  local source_id="$1"
  [[ "$source_id" == *@* ]] || return 1
  printf '%s' "${source_id#*@}"
}

todo_task_find_root() {
  local tasks_json="$1" task_id="$2"
  [[ "$task_id" =~ ^[0-9]+$ ]] || return 1
  jq -ce --argjson id "$task_id" \
    '[.[] | select(.id == $id)] | first // empty' <<<"$tasks_json"
}

todo_task_fingerprint() {
  # Progress flags and modified timestamps change when Manul completes steps.
  # Fiteo also reorders siblings by status/priority/modifiedTime. Exclude the
  # mutable fields and canonicalize sibling arrays by stable priority/id so
  # partial completion can be retried. The prompt itself retains the exact
  # provider-returned order captured during polling.
  jq -cS '
    def stable:
      {
        id,
        description,
        parentTaskId,
        priority,
        scheduler,
        shares:((.shares // []) | sort_by(.userId, .permission)),
        subTasks:([.subTasks[]? | stable] | sort_by([-(.priority // 0), .id]))
      };
    stable
  ' <<<"$1" | sha256sum | awk '{print substr($1, 1, 16)}'
}

todo_task_ids_json() {
  jq -c '
    def ids:
      [.id] + ([.subTasks[]? | ids] | add // []);
    ids
  ' <<<"$1"
}

todo_task_steps_json() {
  jq -c '
    def descendants($depth):
      . as $task
      | [{id:$task.id, description:($task.description // ""), isToDo:(if ($task | has("isToDo")) then $task.isToDo else true end), depth:$depth}]
        + ([ $task.subTasks[]? | descendants($depth + 1) ] | add // []);
    [.subTasks[]? | descendants(0)] | add // []
  ' <<<"$1"
}

todo_strip_manul_trigger() {
  awk '
    {
      if (!found && $0 ~ /^[[:space:]]*\/manul([[:space:]]|$)/) {
        sub(/^[[:space:]]*\/manul([[:space:]]+|$)/, "")
        found = 1
      }
      print
    }
  ' <<<"$1"
}

todo_task_prompt() {
  local task_json="$1" prompt_text steps_json steps_markdown description task_id
  description="$(jq -r '.description // ""' <<<"$task_json")"
  task_id="$(jq -r '.id // "unknown"' <<<"$task_json")"
  prompt_text="$(todo_strip_manul_trigger "$description")"
  steps_json="$(todo_task_steps_json "$task_json")"
  steps_markdown="$(jq -r '
    to_entries[]
    | .key as $index
    | .value as $step
    | (([range(0; ($step.depth // 0)) | "  "] | join(""))
       + (($index + 1 | tostring) + ". ")
       + (if $step.isToDo then "[TODO] " else "[DONE] " end)
       + ($step.description // ""))
  ' <<<"$steps_json")"

  {
    printf '## Todo task\n\n'
    printf '**Todo task ID:** %s\n\n' "$task_id"
    if [ -n "$prompt_text" ]; then
      printf '%s\n' "$prompt_text"
    else
      printf '%s\n' "${description:-Complete the Todo task.}"
    fi
    if [ -n "$steps_markdown" ]; then
      printf '\n## Ordered subtask steps\n\n%s\n' "$steps_markdown"
      printf '\nExecute the pending subtask steps in the exact order shown. Preserve the existing order; nested subtasks follow their parent step immediately. Steps marked [DONE] are context and must not be repeated.\n'
    fi
    printf '\nAfter the implementation is complete and its PR is verified, Manul will mark this Todo task and its subtasks done. Do not change Todo completion state yourself.\n'
  }
}

todo_task_to_source_json() {
  local task_json="$1" source_type="$2" repository="$3"
  local task_id fingerprint source_id source_url title body prompt ids created updated
  task_id="$(jq -r '.id // empty' <<<"$task_json")"
  [[ "$task_id" =~ ^[0-9]+$ ]] || return 1
  fingerprint="$(todo_task_fingerprint "$task_json")"
  source_id="${task_id}@${fingerprint}"
  case "$source_type" in
    todo_local_mcp) source_url="todo-local://task/${source_id}" ;;
    todo_remote_mcp) source_url="fiteo-todo://task/${source_id}" ;;
    *) return 2 ;;
  esac
  title="$(jq -r '.description // "Todo task"' <<<"$task_json")"
  body="$title"
  prompt="$(todo_task_prompt "$task_json")"
  ids="$(todo_task_ids_json "$task_json")"
  created="$(jq -r '.addedTime // ""' <<<"$task_json")"
  updated="$(jq -r '.modifiedTime // .addedTime // ""' <<<"$task_json")"
  jq -cn \
    --arg type "$source_type" \
    --arg sourceId "$source_id" \
    --arg sourceUrl "$source_url" \
    --arg title "$title" \
    --arg body "$body" \
    --arg prompt "$prompt" \
    --arg created "$created" \
    --arg updated "$updated" \
    --arg repository "$repository" \
    --argjson taskId "$task_id" \
    --argjson stepIds "$ids" \
    '{
      taskSourceType:$type,
      taskSourceId:$sourceId,
      taskSourceUrl:$sourceUrl,
      title:$title,
      body:$body,
      prompt:$prompt,
      action:"IMPLEMENT",
      createdAt:$created,
      updatedAt:$updated,
      state:"OPEN",
      metadata:{
        repository:$repository,
        issueNumber:0,
        todoTaskId:$taskId,
        stepIds:$stepIds
      },
      execution:{kind:"repository"}
    }'
}

todo_task_is_active() {
  jq -e '(.isToDo // false) == true and (.scheduler == null)' <<<"$1" >/dev/null 2>&1
}

todo_task_tree_is_done() {
  jq -e '
    def tasks: [.] + ([.subTasks[]? | tasks] | add // []);
    all(tasks[]; .isToDo == false)
  ' <<<"$1" >/dev/null 2>&1
}

todo_task_has_local_trigger() {
  jq -r '.description // ""' <<<"$1" |
    grep -qE '^[[:space:]]*/manul([[:space:]]|$)'
}

todo_task_has_remote_share() {
  local task_json="$1" user_id="$2"
  [[ "$user_id" =~ ^[0-9]+$ ]] || return 1
  jq -e --arg userId "$user_id" '
    any(.shares[]?;
      ((.userId | tostring) == $userId)
      and .permission == "EDITOR_AND_VIEWER"
    )
  ' <<<"$task_json" >/dev/null 2>&1
}

todo_task_still_current() {
  local source_json="$1" source_type="$2" source_id="$3"
  local task_id expected_version tasks_json task_json actual_version
  task_id="$(todo_task_id_from_source_id "$source_id")"
  expected_version="$(todo_task_version_from_source_id "$source_id")" || return 1
  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return 2
  task_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  case "$source_type" in
    todo_local_mcp)
      todo_task_has_local_trigger "$task_json" || return 1 ;;
    todo_remote_mcp)
      local manul_user_id
      manul_user_id="$(jq -r '.manulUserId // empty' <<<"$source_json")"
      todo_task_has_remote_share "$task_json" "$manul_user_id" || return 1 ;;
    *)
      return 2 ;;
  esac
  actual_version="$(todo_task_fingerprint "$task_json")"
  [ "$actual_version" = "$expected_version" ] || return 1
  return 0
}

todo_task_mark_done() {
  local source_json="$1" source_type="$2" source_id="$3"
  local task_id expected_version tasks_json task_json actual_version ids_json arguments tool
  task_id="$(todo_task_id_from_source_id "$source_id")"
  expected_version="$(todo_task_version_from_source_id "$source_id")" || return 1
  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return 1
  task_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  case "$source_type" in
    todo_local_mcp)
      todo_task_has_local_trigger "$task_json" || return 1 ;;
    todo_remote_mcp)
      local manul_user_id
      manul_user_id="$(jq -r '.manulUserId // empty' <<<"$source_json")"
      todo_task_has_remote_share "$task_json" "$manul_user_id" || return 1 ;;
    *)
      return 2 ;;
  esac
  actual_version="$(todo_task_fingerprint "$task_json")"
  [ "$actual_version" = "$expected_version" ] || return 1
  # A lost response after the final root update is still a successful,
  # idempotent completion when the entire tree is already done.
  todo_task_tree_is_done "$task_json" && return 0
  todo_task_is_active "$task_json" || return 1
  ids_json="$(todo_task_ids_json "$task_json")"
  if [ "$source_type" = "todo_local_mcp" ]; then
    arguments="$(jq -c 'reverse' <<<"$ids_json")"
    arguments="$(jq -cn --argjson taskIds "$arguments" '{taskIds:$taskIds}')"
    todo_mcp_source_call "$source_json" "mark_tasks_done" "$arguments" >/dev/null
  else
    # Fiteo's bulk mark tool checks a direct share on every ID. Updating each
    # task individually preserves its existing ancestor-share permission rules.
    # Descendants go first and the root last, so the root stays active if one
    # child update fails and a retry can safely resume the same tree.
    local task_item
    while IFS= read -r task_item; do
      local step_id
      step_id="$(jq -r '.id' <<<"$task_item")"
      arguments="$(jq -cn --argjson id "$step_id" '{id:$id,task:{isToDo:false}}')"
      todo_mcp_source_call "$source_json" "todo_update_task" "$arguments" >/dev/null || return $?
    done < <(jq -c 'def ids: [{id}] + ([.subTasks[]? | ids] | add // []); ids | reverse[]' <<<"$task_json")
  fi
}
