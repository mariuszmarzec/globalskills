---
name: manul-github-bot
description: Setup, operate, and reinstall the manul GitHub command bot (OpenClaw + gh). Manul reacts to `/manul` in issue/PR comments, implements the task on a `manul/*` branch, pushes, optionally opens a PR, and replies with comments signed "manul 🐈". Use when installing manul on a (new) machine, changing its config, or debugging it. This skill directory is the canonical source for all Manul executable scripts. Runtime scripts are symlinked from this directory into `~/.openclaw/manul/`.
---

# Manul GitHub Bot 🐈

Manul (kot stepowy, Pallas's cat) is a GitHub command bot driven by OpenClaw.
It watches configured repositories, reacts to the trigger `/manul` in issue
bodies, issue comments, and PR review comments, and implements the requested
task: inspect → decide informational/change → branch when needed → commit → push → PR → feedback comments on the **same location** that triggered the task. Every comment/PR manul writes is signed
`— manul 🐈`
(identity: **manul** on GitHub, **OpenClaw** in the console).

**Comment routing:** a task triggered by a PR review comment gets its feedback (🤖 Running, ✅ Done, ❌ Failed) posted as an in-thread reply on that review comment; a task triggered by an issue/PR conversation comment or issue body gets its feedback as a top-level issue/PR comment. Cross-posting (e.g. a review-thread task becoming a top-level PR comment) is a bug.

## GitHub Task Workflow

When executing a GitHub issue task, manul **must never modify the repository default branch directly**. The mandatory workflow is:

1. **Prepare an up-to-date isolated base workspace before invoking the agent.** For the initial base, prefer `develop`, then `master`, then the repository default branch.
2. **The agent decides whether the task is informational or requires repository changes.** Informational tasks do not create branches or modify the repository.
3. **For repository changes, the agent creates the dedicated branch** and follows the `feature-branching-strategy` skill for branch naming and base selection.
4. **Make all task commits on the agent's task branch** — never on the chosen base/default branch.
5. **Push the task branch** to GitHub and deliver repository changes through a GitHub PR targeting the branch the task branch was created from.
6. **Do not report a repository-change task as successfully completed** if the required PR could not be created.

## Automated GitHub Comment Signature

Every comment or PR review comment that manul posts must include the signature:

```
— manul 🐈
```

Rules for the signature:

* The signature **must be separated from the comment body by two newlines**.
* **Do not append a duplicate signature** if the comment already ends with `— manul 🐈`.
* A signature occurring in the **middle** of the body does **not** prevent appending the final signature.

```
        /\_/\
       ( o.o )   manul 🐈 — GitHub command bot
        > ^ <
```

## Runtime Layout

Manul uses a **two-directory layout**:

| Directory | Contents | Notes |
|---|---|---|
| `~/.globalskills/skills/manul-github-bot/` | **Canonical source** — all scripts, prompts, docs | Single source of truth for executable code |
| `~/.openclaw/manul/` | **Runtime** — scripts (via symlinks) + data | Scripts are symlinks; data is local copies |

**Why this split?** The runtime directory lives on native ext4 (`~/.openclaw/manul/`) for performance and reliability:
- SQLite database (`manul.db`) requires native filesystem I/O for correct concurrent access
- Repository worktrees and large Git operations run faster on ext4 than on 9p mounts
- The workspace (`workspace/`) contains cloned repositories that persist across reboots
- Logs, locks, and DB remain accessible from any WSL2 or native Linux path

**Scripts are symlinked, not copied:** Changes to canonical scripts are immediately reflected at runtime.

```
GitHub
  ↓
poll.sh
  ↓
SQLite (single source of truth)
  ↓
queued
  ↓
manul-daemon.sh
  ↓
running
  ↓
heartbeat + lease
  ↓
done / failed

watchdog.sh
  ↓
automatic stale-task recovery
```

**Explicit separation of responsibilities:**

| Component | Responsibility |
|-----------|----------------|
| `poll.sh` | GitHub polling, deduplication and enqueueing only (no recovery) |
| `SQLite manul.db` | single source of truth for all task state |
| `manul-daemon.sh` | consumes queued tasks, posts lifecycle/status comments, manages orchestrator execution |
| `watchdog.sh` | ONLY automatic recovery/liveness mechanism (daemon liveness, stale lock removal, heartbeat/lease-based task recovery) |
| `task-recovery.sh` | manual/admin recovery tool only (NOT automatic) |
| `task-health-check.sh` | LEGACY/DEPRECATED; MUST NOT be part of automatic operation |

**Agent Comment Posting Contract:**

Previously, the agent posted nothing to GitHub — the daemon extracted agent output from stdout and posted the result. **Under the new contract, the agent MUST post its own user-facing GitHub comment directly before `TASK_DONE`.**

- **Agent responsibility:** After completing the task, post a GitHub comment with the result.
- **Comment format:** Follow the existing automated GitHub comment signature rules (see "Automated GitHub Comment Signature" section). Include the signature `— manul 🐈` separated by two newlines.
- **Comment timing:** Post exactly one comment per task (the final result), **before** emitting `TASK_DONE`.
- **Comment routing:** Same as existing manul comment routing (top-level for issue/PR comments, in-thread reply for PR review comments).
- **Daemon behavior:** The daemon no longer extracts `AGENT_RESPONSE` from agent stdout. The agent comment is the source of truth for user-facing results.
- **Lifecycle comments:** The daemon continues to post lifecycle/status comments (`🔄 working`, `✅ completed`, `❌ failed`) on its own responsibility.
- **No comment posting rules:** The orchestrator prompt no longer restricts agents from posting GitHub comments — posting a result comment is now required.

**Result Comment Marker (deterministic task/attempt correlation):**

Every agent result comment MUST include an invisible HTML comment marker that identifies the exact task execution attempt:

```
<!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->
```

Where:
- `<COMMENT_ID>` is the task's `commentId` from the database (e.g. `5599133859`)