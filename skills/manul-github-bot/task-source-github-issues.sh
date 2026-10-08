#!/usr/bin/env bash
# GitHub Issues task-source provider. PRs are never roots.
set -uo pipefail

task_source_github_issues_poll() {
  local source_json="$1" repo baseline trigger
  baseline="$(jq -r '.baseline // ""' <<<"$source_json")"
  trigger="$(jq -r '.trigger // "/manul"' <<<"$source_json")"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    gh api --paginate "repos/$repo/issues?state=open&since=${baseline}&per_page=100" 2>/dev/null |
      jq -c --arg repo "$repo" --arg trigger "$trigger" '
        .[] | select(.pull_request | not)
        | select((.body // "") | test("(^|\\r?\\n)[ \\t]*" + ($trigger | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\$&")) + "([ \\t\\r\\n]|$)"))
        | {taskSourceType:"github_issues", taskSourceId:($repo + "#" + (.number|tostring)), taskSourceUrl:.html_url,
           title:(.title // ""), body:(.body // ""), prompt:((.body // "") | sub("^[ \\t]*" + $trigger + "[ \\t]*"; "")), createdAt:(.created_at // ""),
           updatedAt:(.updated_at // .created_at // ""), state:"OPEN",
           metadata:{repository:$repo, issueNumber:.number}}'
  done
  <<<"$(jq -r ".repositories[]?" <<<"$source_json")"
}
