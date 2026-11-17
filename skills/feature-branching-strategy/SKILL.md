---
name: feature-branching-strategy
description: Branching strategy for changes made by an AI agent. Use whenever pushing code changes to a repository (except the ~/.globalskills repo). Create a dedicated branch with a natural, task-focused name that follows repository conventions, without exposing internal task sources or automation metadata.
license: MIT
---

# Feature Branching Strategy

Every change pushed by an AI agent must live on a dedicated branch, never on the default/main branch directly.

## Rules

- Always create a new branch before committing and pushing changes.
- Never push directly to the default branch (e.g. `master`, `main`).
- Never commit or push from the default branch.
- This requirement applies to all repositories **except** `~/.globalskills`, where direct pushes to `master` are allowed.

## The `~/.globalskills` repository

- In `~/.globalskills`, changes are committed and pushed directly to `master` by default — no branch is created unless the user **explicitly asks** for a new branch.
- Do not assume branching is wanted for globalskills changes; only create a branch there when the user prompt explicitly requests it.

## Base branch

- If the user prompt does not explicitly name a base branch, branch off **`develop`** when it exists locally or on the remote.
- If `develop` is not present, branch off **`master`** (or the repository's default branch).
- Always **pull the latest changes from the remote** before creating the new branch, then start the work.
- When the user prompt does name a specific base branch, use that branch and still pull the latest remote changes from it first.

## Branch naming

Choose a branch name that describes the requested code change, not the way the work was dispatched or the tool that performs it.

- Follow an established naming convention already used by the repository.
- When the repository has no naming convention, use a short, natural, lowercase kebab-case description. Add a type prefix only when it is normal for that repository (for example, `feature/`, `bugfix/`, `refactor/`, or `chore/`).
- Describe the outcome or behavior being changed, using a few meaningful words. Avoid generic names such as `feature`, `fix`, or `work`.
- Do not add task-source/provider names, orchestration/tool names, runtime or agent names, MCP server names, internal IDs, comment IDs, attempt numbers, or other execution metadata. In particular, names such as `manul`, `todo`, `mcp`, `opencode`, `openclaw`, `codex`, or `claude-code` must not appear when they only describe the internal execution path. They are valid only when genuinely part of the requested product/domain change.
- Do not copy Todo task IDs or other provider-generated identifiers into branch names. Include a GitHub issue number only when the repository's established convention explicitly requires it.
- If a branch name already exists, add a plain numeric suffix such as `-2` or `-3` until it is unique. Never use task IDs or attempt metadata to make a branch unique.

Examples:

```
improve-session-renewal
fix-empty-search-state
refactor-token-refresh
feature/add-offline-sync
```

## Workflow

1. Check the current branch: `git branch --show-current`.
2. Pick the base branch:
   - Use `develop` if it exists (local or remote); otherwise use `master`.
   - Use the branch named in the user prompt when one is given.
3. Fetch and pull the latest changes from the remote for the base branch before branching:

   ```bash
   git fetch origin
   git checkout develop     # or master / the branch from the user prompt
   git pull origin develop  # or master
   ```

4. Create the new branch from the up-to-date base branch:

   ```bash
   git checkout -b <BRANCH_NAME>
   ```

5. Make changes, commit, and push:

   ```bash
   git push -u origin <BRANCH_NAME>
   ```

6. For a new standalone task, do NOT reuse a branch left by a previous task attempt unless that branch is already tied to a live PR for this exact task. If the requested branch name already exists without such a PR, create a unique task branch (for example, append a short task/attempt suffix) and use that branch for the new work.

## Resolving PR conflicts

Conflict resolution for a PR must be done on that PR's **source branch**, then pushed back, so GitHub updates the same PR.

Preferred flow:
1. Fetch and check out the PR's source branch, e.g. `git fetch origin && git checkout -b pr/22 origin/pr/22` or the existing feature branch behind the PR.
2. Pull/rebase onto the latest target branch: `git pull --rebase origin master` (or the actual base).
3. Resolve conflicts, commit, and push the same branch: `git push --force-with-lease origin pr/22`.
4. Do **not** merge the target branch into the PR branch locally and stop there without pushing/updating the PR.
5. If a separate resolution branch is absolutely needed, open a **new PR** from it; do not leave the resolution only on a local/resolution branch with no PR.

Never:
- Merge the target branch into the PR branch locally and leave the result without pushing/updating the PR.
- Leave conflict resolution only on a throwaway branch without a PR.
- Rewrite public branch history carelessly; use `--force-with-lease` when required.

## Creating a pull request

**The PR base branch must be the branch that the feature branch was created from, not the repository default.**

Determine the correct base branch before creating the PR:

1. If the feature branch was explicitly created from a named base branch, use that branch.
2. If there is a `develop` branch and the feature branch was based on it, use `develop`.
3. Otherwise, use the repository default branch.

Once the branch is pushed, open a PR with the GitHub CLI (`gh`):

```bash
gh pr create --base <parent-branch> --head <BRANCH_NAME> \
  --title "<short, descriptive title>" --body "<meaningful description>"
```

- Always use the `gh` CLI to create pull requests.
- The PR title and description must be a **meaningful but short** summary of the changes:
  - Title: concise, imperative or descriptive, e.g. `Add mock mode to vitalia.py`.
  - Body: a brief summary of what changed and why, plus verification steps if useful (e.g. test results). No walls of text.
- Link the issue in the body when one exists: `Closes #<ISSUE_NUMBER>`.
- After the first push of a standalone task branch, create a meaningful PR immediately. After EVERY later push to a branch with an open PR (including checkpoints and fixes), follow `pr-description-management` to refresh the full description from the cumulative diff and current verification, then read it back to verify it; never leave description maintenance until the final push.

## Never

- Never push directly to the default branch (except in `~/.globalskills`).
- Never create a branch in `~/.globalskills` unless the user explicitly asked for one.
- Never push changes made without a branch.
- Never create branches with ambiguous names like `feature` or `fix`.
- Never create a branch without first pulling the latest remote changes for the base branch.
- Never create a PR without a meaningful short description of the changes.
