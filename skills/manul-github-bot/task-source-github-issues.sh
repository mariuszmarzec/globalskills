#!/usr/bin/env bash
# GitHub Issues task-source provider. PRs are never roots.
set -uo pipefail

task_source_github_issues_poll() {
  local source_json="$1" repo baseline trigger allowed_json
  baseline="$(jq -r '.baseline // ""' <<<"$source_json")"
  trigger="$(jq -r '.trigger // "/manul"' <<<"$source_json")"
  allowed_json="$(jq -c '.allowedUsers // []' <<<"$source_json")"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    effective_allowed_json="$allowed_json"
    # Preserve the existing GitHub default when config still contains the
    # unresolved example placeholder. Real configured users are kept.
    if printf '%s' "$effective_allowed_json" | jq -e 'any(.[]; test("[<>]"))' >/dev/null 2>&1; then
      effective_allowed_json="$(printf '%s' "$effective_allowed_json" | jq -c '[.[] | select(test("[<>]") | not)]')"
      if [ "$(printf '%s' "$effective_allowed_json" | jq 'length')" -eq 0 ]; then
        effective_allowed_json="$(jq -nc --arg repo_owner "$(printf '%s' "$repo" | cut -d/ -f1)" '[$repo_owner]')"
      fi
    fi
    gh api --paginate "repos/$repo/issues?state=open&since=${baseline}&per_page=100" 2>/dev/null |
      jq -c --arg repo "$repo" --arg trigger "$trigger" --arg baseline "$baseline" --argjson allowed "$effective_allowed_json" '
        .[] | select(.pull_request | not)
        | select(.created_at >= $baseline)
        | select(($allowed | length == 0) or (.user.login as $u | ($allowed | index($u)) != null))
        | select((.body // "") | test("(^|\\r?\\n)[ \\t]*" + ($trigger | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\$&")) + "([ \\t\\r\\n]|$)"))
        | {taskSourceType:"github_issues", taskSourceId:($repo + "#" + (.number|tostring)), taskSourceUrl:.html_url,
           title:(.title // ""), body:(.body // ""), prompt:((.body // "") | sub("^[ \\t]*" + $trigger + "[ \\t]*"; "")), createdAt:(.created_at // ""),
           updatedAt:(.updated_at // .created_at // ""), state:"OPEN",
           metadata:{repository:$repo, issueNumber:.number}}'
  done
  <<<"$(jq -r ".repositories[]?" <<<"$source_json")"
}
