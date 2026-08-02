---
name: feature-branching-strategy
description: Branching strategy for changes made by an AI agent. Use whenever pushing code changes to a repository (except the ~/.globalskills repo) — always create a feature/<ISSUE_NUMBER-if-exists>-<DESCRIPTION> branch, or bugfix/<DESCRIPTION> for bug fixes, and never push directly to the main branch.
license: MIT
---

# Feature Branching Strategy

Every change pushed by an AI agent must live on a dedicated branch, never on the default/main branch directly.

## Rules

- Always create a new branch before committing and pushing changes.
- Never push directly to the default branch (e.g. `master`, `main`).
- Never commit or push from the default branch.
- This requirement applies to all repositories **except** `~/.globalskills`, where direct pushes to `master` are allowed.

## Branch naming

### Feature changes

```
feature/<ISSUE_NUMBER>-<DESCRIPTION>
```

Use `feature/` for new features, improvements, refactors, and chores.

- `<ISSUE_NUMBER>` — the GitHub issue/PR number if one exists. Omit it when there is no associated issue.
- `<DESCRIPTION>` — short, kebab-case (lowercase, dash-separated) description of the change.

Examples:

```
feature/42-google-login
feature/23-dark-mode
feature/update-README
```

### Bug fixes

```
bugfix/<ISSUE_NUMBER>-<DESCRIPTION>
```

Use `bugfix/` when the change fixes a bug. Same naming rules as `feature/`.

Examples:

```
bugfix/17-login-crash
bugfix/89-null-pointer-in-cart
bugfix/fix-ci-build
```

## Workflow

1. Check the current branch: `git branch --show-current`.
2. If not already on the target branch, create it:

   ```bash
   git checkout master   # or the default branch
   git pull
   git checkout -b feature/<ISSUE_NUMBER>-<DESCRIPTION>
   ```

3. Make changes, commit, and push:

   ```bash
   git push -u origin feature/<ISSUE_NUMBER>-<DESCRIPTION>
   ```

4. If a feature branch for the work already exists, reuse it instead of creating a new one.

## Creating a pull request

Once the branch is pushed, open a PR with the GitHub CLI (`gh`):

```bash
gh pr create --base <default-branch> --head feature/<ISSUE_NUMBER>-<DESCRIPTION> \
  --title "<short, descriptive title>" --body "<meaningful description>"
```

- Always use the `gh` CLI to create pull requests.
- The PR title and description must be a **meaningful but short** summary of the changes:
  - Title: concise, imperative or descriptive, e.g. `Add mock mode to vitalia.py`.
  - Body: a brief summary of what changed and why, plus verification steps if useful (e.g. test results). No walls of text.
- Link the issue in the body when one exists: `Closes #<ISSUE_NUMBER>`.

## Never

- Never push directly to the default branch (except in `~/.globalskills`).
- Never push changes made without a branch.
- Never create branches with ambiguous names like `feature` or `fix`.
- Never create a PR without a meaningful short description of the changes.
