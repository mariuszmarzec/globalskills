---
name: manul-github-bot
description: Operate, install, and debug the Manul GitHub command bot. Manul reacts to /manul commands in issues and PRs, manages isolated tasks and workspaces, invokes the current agent runtime, verifies results, and posts feedback signed "manul 🐈". The canonical executable source is this skill directory.
---

# Manul GitHub Bot 🐈

Manul is a GitHub command bot and local task orchestrator.

It watches configured repositories, reacts to `/manul` in issue bodies, issue/PR conversation comments, and PR review comments, then:

- creates or resumes a task;
- prepares an isolated workspace;
- lets the agent determine whether the request is informational or requires repository changes;
- executes the task through the current agent runtime;
- verifies the result;
- pushes repository changes and verifies a real PR when required;
- posts lifecycle and result feedback on the original GitHub conversation.

Every Manul-authored comment ends with:

`— manul 🐈`

Read these files before making architectural changes:

- `AGENTS.md` — agent guardrails;
- `ARCHITECTURE.md` — ownership/dependency model;
- `CONTRACTS.md` — behavioural invariants.

## Current master runtime

The current master implementation uses:

```
MANUL_DIR=${MANUL_DIR:-$HOME/.openclaw/manul}
```

The installer currently deploys the runtime scripts as symlinks.

Canonical source:

```
~/.globalskills/skills/manul-github-bot/
```

Current runtime:

```
~/.openclaw/manul/
```

The current runtime contains Manul configuration, SQLite state, logs, locks, task artifacts, workspace state, and runtime script links.

Some older helpers accept `OPENCLAW_MANUL_DIR` as an environment alias. That is current implementation detail, not a desired long-term dependency.

## Approved next architecture

The next refactor intentionally separates Manul from OpenClaw:

```
~/.manul/
├── config.json
├── state/
│   ├── manul.db
│   ├── locks/
│   └── tasks/
├── logs/
└── workspace/
```

OpenClaw remains in its own environment:

```
~/.openclaw/
```

The agent boundary will become:

```
Manul -> AgentExecutor -> OpenClawAdapter
                         -> OpenCodeAdapter
                         -> other adapters
```

This target is documented now so agents do not entrench the current OpenClaw coupling. It is not implemented on the current master yet.

## GitHub task workflow

### Issue task

1. Prepare an up-to-date isolated base workspace. Prefer `develop`, then `master`, then the repository default branch unless the task explicitly requires another base.
2. Determine whether the request is informational or a repository change.
3. Informational tasks do not create a branch and do not modify the repository.
4. Repository-change tasks create the required feature/bugfix branch using the branching strategy skill.
5. Commit only on the task branch.
6. Push the task branch.
7. Open and verify a real GitHub PR targeting the branch used as the task base.
8. Do not report successful completion when the required PR cannot be verified.

### Existing PR review/conversation task

Reuse the PR's existing head branch. Do not create an unrelated task branch.

The task must update the same PR.

## Comment routing

Review-comment tasks reply in the original review thread.

Issue-body and issue/PR conversation tasks use top-level issue/PR comments.

Cross-posting a review-thread task as a top-level PR comment is a bug.

## Result contract

The agent must post exactly one user-facing result comment before emitting `TASK_DONE`.

The comment contains:

```html
<!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->
```

The daemon verifies this marker against GitHub before accepting completion.

Lifecycle comments are separate daemon responsibilities.

## State and recovery

Core task flow:

```
queued -> running -> completed
                  -> failed
                  -> blocked_user
                  -> stale -> queued
```

`attempts` increments only when a queued task is claimed for execution.

Recovery from running to queued preserves the attempt count.

`blocked_user` is not failure and resumes through `/manul continue <answer>`.

The daemon performs a startup stale-task recovery pass. The watchdog is the periodic liveness/recovery process.

SQLite is authoritative for task state.

## GitHub control commands

Supported `/manul` commands:

```
/manul run <task>
/manul run --agent <agent> <task>
/manul review-fix <prompt>
/manul continue <answer>
/manul verify <prompt>
/manul status
/manul close
```

See `GITHUB_CONTROL_PROTOCOL.md` for machine-readable details.

## Local CLI

The local control interface consists of:

```
manul-submit.sh
manul-status.sh
manul-result.sh
manul-wait.sh
manul-conversation.sh
manul-orchestrator.sh
```

See `LOCAL_INTERFACE.md` and `ORCHESTRATOR.md`.

## Main operational scripts

| Script | Responsibility |
|---|---|
| `poll.sh` | Poll GitHub, parse commands/events, deduplicate, enqueue |
| `manul-daemon.sh` | Claim tasks, run agent, heartbeat, verify completion, update state |
| `watchdog.sh` | Periodic liveness and stale-task recovery |
| `workspace-manager.sh` | Workspace pool, leases, release/reclaim |
| `manul-github-events.sh` | Parse/control GitHub command events |
| `manul-conversation.sh` | Conversation/task local state interface |
| `manul-pr-review.sh` | Convert PR review events into Manul tasks |
| `manul-result-feedback.sh` | Publish structured task lifecycle/result events |
| `manul-result.sh` | Read completed/failed task results |
| `manul-status.sh` | Inspect task state/logs |
| `manul-submit.sh` | Submit local tasks |
| `manul-wait.sh` | Wait for task completion/blocking |
| `manul-orchestrator.sh` | External conversation/review orchestration |

`task-health-check.sh` is legacy/deprecated and must not be installed as an automatic recovery mechanism.

## Configuration

The canonical configuration template is:

```
config.json.example
```

Current automation controls include:

```
agentTimeoutSeconds
heartbeatInterval
heartbeatTimeout
leaseTimeout
maxConcurrentTasks
maxAttemptsBeforeFail
lockTtl
```

Other top-level controls include:

- trigger;
- allowed users;
- repositories;
- agent list;
- PR creation/rebase behaviour;
- retry/context strategy;
- compaction;
- CI-fix policy.

Do not put provider-global configuration into Manul's config merely because the current runtime happens to be OpenClaw.

## Installation

Current installer:

```bash
bash skills/manul-github-bot/install-manul.sh
```

Useful options:

```
--runtime-dir <path>
--canonical-dir <path>
--init-state
```

The installer currently:

- verifies dependencies;
- creates the runtime directory;
- deploys runtime symlinks;
- initializes configuration when absent;
- prepares/validates the DB;
- installs the watchdog cron;
- installs the zsh shell integration.

The current installer deliberately does not start the daemon automatically.

The upcoming runtime isolation refactor is allowed to replace this layout with a fresh `~/.manul` installation. It does not need to migrate obsolete `.openclaw/manul` state.

## Verification

Relevant test entry points include:

```bash
bash skills/manul-github-bot/test_runtime_health.sh
bash skills/manul-github-bot/test_manul_cli.sh
bash skills/manul-github-bot/test_github_control_protocol.sh
bash skills/manul-github-bot/test_orchestrator.sh
```

Architecture changes should run the broad relevant test suite rather than only a single focused test.

## Troubleshooting

### Daemon not running

Check:

```bash
manul --status
manul-status.sh --log --tail=200
```

Then inspect the configured runtime directory and daemon PID.

### Watchdog not acting

Check the cron entry and the `.enabled` marker.

The watchdog is intentionally dormant until Manul has been explicitly started.

### Stale task

Inspect:

```bash
manul-status.sh --list
task-recovery.sh --list-stuck
```

Use task recovery only for manual intervention; normal stale recovery belongs to the daemon/watchdog mechanisms.

### OpenClaw execution failure

Check:

- OpenClaw is installed and reachable;
- the current OpenClaw `main` agent exists;
- the OpenClaw gateway/runtime is healthy;
- the Manul agent prompt/config is valid.

The long-term design should isolate these runtime-specific checks inside the OpenClaw adapter.
