#!/usr/bin/env bash
# task-source.sh — runtime-neutral Manul task source contracts and registry.
#
# A task source owns the ROOT work item Manul executes.
# Pull requests and review artifacts are related context, never root sources.

set -uo pipefail
TASK_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

task_source_types() { printf '%s\n' github_issues jira_tasks; }

task_source_type_is_supported() {
  case "$1" in github_issues|jira_tasks) return 0 ;; *) return 1 ;; esac
}

task_source_enabled() { jq -e '(.enabled // true) == true' <<<"$1" >/dev/null 2>&1; }
task_source_name() { jq -r '.type // empty' <<<"$1"; }

task_source_poll() {
  local source_json="$1" type
  type="$(task_source_name "$source_json")"
  case "$type" in
    github_issues)
      source "$TASK_SOURCE_DIR/task-source-github-issues.sh"
      task_source_github_issues_poll "$source_json" ;;
    jira_tasks)
      source "$TASK_SOURCE_DIR/task-source-jira-tasks.sh"
      task_source_jira_tasks_poll "$source_json" ;;
    *)
      echo "task-source: unsupported provider type: $type" >&2
      return 2 ;;
  esac
}

task_source_normalize_id() { printf "%s:%s" "$1" "$2"; }

task_source_configured_sources() {
  local config="$1"
  if jq -e '(.taskSources // []) | length > 0' "$config" >/dev/null 2>&1; then
    jq -c '.taskSources[] | select((.enabled // true) == true)' "$config"
    return 0
  fi
  jq -c '{type:"github_issues", enabled:true, repositories:(.repositories // [])}' "$config"
}

task_source_identity() {
  jq -r '.taskSourceType as $t | .taskSourceId as $i | if ($t // "") == "" or ($i // "") == "" then empty else ($t + ":" + $i) end' <<<"$1"
}


task_source_poll_all() {
  local config="$1" source_json baseline trigger
  baseline="$(jq -r ".baseline // empty" "$config")"
  trigger="$(jq -r '.trigger // "/manul"' "$config")"
  while IFS= read -r source_json; do
    [ -n "$source_json" ] || continue
    source_json="$(jq -c --arg baseline "$baseline" --arg trigger "$trigger" '.baseline=$baseline | .trigger=$trigger' <<<"$source_json")"
    task_source_poll "$source_json"
  done < <(task_source_configured_sources "$config")
}
