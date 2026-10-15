---
name: pr-description-management
description: Manage GitHub Pull Request descriptions - create PRs with proper descriptions and update descriptions when pushing changes. Uses gh CLI for all PR operations. Follows feature-branching-strategy for branch naming.
---

# PR Description Management

## Purpose
Ensure every PR created or updated has a meaningful description. This skill covers creating PRs with descriptions and updating existing PR descriptions when pushing new commits.

## When to Use
**Mandatory** — use this skill every time work is completed and a branch is pushed to GitHub:
- After pushing a new feature branch for the first time: **create a PR with a description**
- After pushing additional commits to an existing PR branch: **update the PR description**
- Any time you push changes that should be reflected in the PR description

Do not stop at "branch pushed" — always ensure a PR exists and its description is accurate.

## Prerequisites
- `gh` CLI installed and authenticated (`gh auth status` shows logged in)
- Repository is a GitHub repository (has an `origin` remote pointing to GitHub)
- Feature branch follows `feature/<ISSUE_NUMBER>-<DESCRIPTION>` or `bugfix/<DESCRIPTION>` naming (per feature-branching-strategy)

## Workflow
PR description maintenance is part of every delivery push, not a one-time cleanup.

- On the first push of a standalone task branch, create a real PR immediately with a meaningful, non-empty body (including when the first push is a checkpoint).
- After EVERY later push to a branch with an open PR—including checkpoint, review-fix, and CI-fix pushes—refresh that same PR's description before continuing work or claiming delivery.
- Rebuild the body from the cumulative current PR diff and current verification results. Keep Summary, Changes, Testing, and related-issue references accurate. Do not blindly append a bullet for the latest commit; that can leave stale or duplicated content.
- If PR creation/update or read-back verification fails, report the exact blocker and do not claim delivery success.

## Base branch for PR

**The PR base branch must be the branch that the feature branch was created from, not the repository default.**

Determine the correct base branch before creating or editing the PR:

1. If the feature branch was explicitly created from a named base branch, use that branch.
2. If there is a `develop` branch and the feature branch was based on it, use `develop`.
3. Otherwise, use the repository default branch.

### 1. Create PR with Description (First Push)
After pushing a new feature branch for the first time, immediately create a PR.

> ⚠️ **Shell quoting pitfall:** Never pass `--body` as a double-quoted string when the description contains backticks, code spans, or shell-special characters. In bash/zsh, backticks inside double quotes trigger command substitution — the shell tries to execute the content as a command and replaces it with empty output, silently mangling the PR body. Use a **heredoc** or a **single-quoted** string instead.

```bash
# Push the branch first
git push -u origin <branch-name>

# Create PR with description (heredoc — safe for backticks and special chars)
gh pr create \
  --title "<PR Title>" \
  --base <parent-branch> \
  --head <branch-name> \
  --body "$(cat <<'EOF'
<PR Description>
EOF
)"
```

**Verification step:** After creating the PR, always inspect the body to confirm it wasn't mangled:
```bash
gh pr view <PR_NUMBER> --json body --jq '.body'
```

**PR Description Template:**
```markdown
## Summary
<Brief description of what this PR does>

## Changes
- <Change 1>
- <Change 2>
- <Change 3>

## Testing
- <How to test / what was tested>

## Related Issues
Closes #<ISSUE_NUMBER> (if applicable)
```

### 2. Refresh the description after EVERY subsequent push
After every additional push to an existing PR branch, immediately update that same PR's description. This includes checkpoint pushes, review fixes, CI fixes, and any later implementation change. The body must describe the cumulative current PR diff, not just the latest commit.

1. Inspect the complete current PR diff and commit range, plus the verification performed since the last update.
2. Rewrite the complete body so Summary, Changes, Testing, and related-issue links are accurate; preserve valid issue-closing references. Do not append blindly to the previous body.
3. Save the complete Markdown body to a temporary file using a quoted heredoc so backticks, `$(...)`, and other content remain literal:

```bash
PR_NUMBER="<existing PR number>"
BODY_FILE="$(mktemp)"
cat >"$BODY_FILE" <<'PR_BODY_EOF'
## Summary
<Current overall purpose of the PR>

## Changes
- <All relevant changes in the current PR, with no duplicate/stale entries>

## Testing
- <Current verification and results>

## Related Issues
Closes #<ISSUE_NUMBER> (if applicable)
PR_BODY_EOF

gh pr edit "$PR_NUMBER" --body-file "$BODY_FILE"
gh pr view "$PR_NUMBER" --json body,url,headRefName,baseRefName,headRefOid
ACTUAL_BODY="$(gh pr view "$PR_NUMBER" --json body --jq '.body')"
EXPECTED_BODY="$(cat "$BODY_FILE")"
[[ "$ACTUAL_BODY" == "$EXPECTED_BODY" ]] || {
  echo "PR description read-back does not match the submitted body" >&2
  exit 1
}
rm -f "$BODY_FILE"
```

Verify that the body is non-empty and current, that the URL/head/base identify the expected PR, and that `headRefOid` equals the pushed commit. If any update or verification fails, the push is not fully delivered and the blocker must be reported.

### 3. Get PR Number for Current Branch
```bash
# Get PR number associated with current branch
gh pr list --head <branch-name> --json number --jq '.[0].number'

# Or get PR number from current branch if checked out
gh pr view --json number --jq '.number'
```

## Automation Script
Use a helper that replaces the body with a complete, freshly reviewed description. Do not append one line to the old body: repeated runs can duplicate entries and leave stale details.

```bash
#!/bin/bash
# pr-update.sh - replace a PR description with the complete current description
# Usage: ./pr-update.sh path/to/complete-pr-description.md
set -euo pipefail

BRANCH="$(git branch --show-current)"
BODY_FILE="${1:?Usage: $0 path/to/complete-pr-description.md}"
if [[ ! -s "$BODY_FILE" ]]; then
  echo "PR description file is missing or empty: $BODY_FILE" >&2
  exit 1
fi

PR_NUMBER="$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
if [[ -z "$PR_NUMBER" || "$PR_NUMBER" == "null" ]]; then
  echo "No open PR found for branch $BRANCH" >&2
  exit 1
fi

gh pr edit "$PR_NUMBER" --body-file "$BODY_FILE"
EXPECTED_BODY="$(cat "$BODY_FILE")"
ACTUAL_BODY="$(gh pr view "$PR_NUMBER" --json body --jq '.body')"
if [[ "$ACTUAL_BODY" != "$EXPECTED_BODY" ]]; then
  echo "PR #$PR_NUMBER body does not match the submitted description" >&2
  exit 1
fi

gh pr view "$PR_NUMBER" --json body,url,headRefName,baseRefName,headRefOid
echo "PR #$PR_NUMBER description updated and read-back verified"
```

## Rules
1. **Always** create PR with `--body` flag, never rely on default template
2. **Always** update and read back the full, cumulative PR description immediately after every push to an existing PR, including checkpoints and review/CI fixes; do not append blindly
3. Use descriptive commit messages that can be reflected in PR description
4. Reference related issues with `Closes #<NUMBER>` or `Refs #<NUMBER>`
5. Keep "Changes" section in sync with actual commits
6. Run tests/lint before pushing and note results in description
7. **Always verify the PR body after creation or edit** — backticks and special characters can be mangled by unsafe shell interpolation; prefer `--body-file` and read the body back

## Verification
After creating/updating PR:
```bash
# Verify PR exists and has description
gh pr view <PR_NUMBER> --json title,body,url
```

## Related Skills
- `feature-branching-strategy` - Branch naming conventions
- `ai-commit-attribution` - Commit author/co-author attribution
