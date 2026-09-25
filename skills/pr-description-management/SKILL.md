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
This is the final step after any push. Do not consider the task complete until the PR is created or updated.

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

### 2. Update PR Description (Subsequent Pushes)
After pushing additional commits to an existing PR branch, immediately update the PR description. Use the same heredoc pattern to avoid the backtick command-substitution pitfall:

```bash
# Push changes
git push origin <branch-name>

# Update PR description to reflect new changes (heredoc — safe for backticks)
gh pr edit <PR_NUMBER> \
  --body "$(cat <<'EOF'
<UPDATED_PR_DESCRIPTION>
EOF
)"
```

**Updated Description Template:**
```markdown
## Summary
<Brief description of what this PR does>

## Changes
- <Change 1>
- <Change 2>
- <Change 3>
- <New change from latest commit>

## Testing
- <How to test / what was tested>

## Related Issues
Closes #<ISSUE_NUMBER> (if applicable)
```

### 3. Get PR Number for Current Branch
```bash
# Get PR number associated with current branch
gh pr list --head <branch-name> --json number --jq '.[0].number'

# Or get PR number from current branch if checked out
gh pr view --json number --jq '.number'
```

## Automation Script
Create a helper script for consistent PR management:

```bash
#!/bin/bash
# pr-update.sh - Update PR description after push
# Usage: ./pr-update.sh "New change description"

set -euo pipefail

BRANCH=$(git branch --show-current)
PR_NUMBER=$(gh pr list --head "$BRANCH" --json number --jq '.[0].number')

if [[ -z "$PR_NUMBER" || "$PR_NUMBER" == "null" ]]; then
  echo "No PR found for branch $BRANCH"
  exit 1
fi

# Get current PR body
CURRENT_BODY=$(gh pr view "$PR_NUMBER" --json body --jq '.body')

# Append new change to Changes section
NEW_CHANGE="$1"
UPDATED_BODY=$(echo "$CURRENT_BODY" | sed "/## Changes/a\\- $NEW_CHANGE")

# Update PR
gh pr edit "$PR_NUMBER" --body "$UPDATED_BODY"
echo "PR #$PR_NUMBER description updated"
```

## Rules
1. **Always** create PR with `--body` flag, never rely on default template
2. **Always** update PR description after pushing new commits to an existing PR
3. Use descriptive commit messages that can be reflected in PR description
4. Reference related issues with `Closes #<NUMBER>` or `Refs #<NUMBER>`
5. Keep "Changes" section in sync with actual commits
6. Run tests/lint before pushing and note results in description
7. **Always verify the PR body after creation or edit** — backticks and special characters in `--body` can be silently mangled by shell command substitution

## Verification
After creating/updating PR:
```bash
# Verify PR exists and has description
gh pr view <PR_NUMBER> --json title,body,url
```

## Related Skills
- `feature-branching-strategy` - Branch naming conventions
- `ai-commit-attribution` - Commit author/co-author attribution
