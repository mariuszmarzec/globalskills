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

In `bot` mode, every Manul-authored comment ends with:

`— manul 🐈`

The top-level configuration key `mode` controls attribution behavior. It defaults to `bot`. In `human` mode, Manul does not append its signature, does not publish lifecycle/status/error comments, and AI-created commits must not contain a `Co-authored-by` trailer. The agent still posts its actual user-facing result comment.

Read these files before making architectural changes:

- `AGENTS.md` — agent guardrails;
- `ARCHITECTURE.md` — ownership/dependency model;
- `CONTRACTS.md` — behavioural invariants.

## Current runtime

The current implementation uses:

```
MANUL_DIR=${MANUL_DIR:-$HOME/.manul}
```

Path resolution and `AGENT_RUNTIME` validation are centralized in
`manul-paths.sh`. There is no `OPENCLAW_MANUL_DIR` alias and no fallback to
`~/.openclaw/manul`.

The installer deploys the runtime scripts as symlinks.

Canonical source:

```
~/.globalskills/skills/manul-github-bot/
```

Current runtime:

```
~/.manul/
├── config.json
├── .env                # operator/provider environment for unattended runs
├── state/
│   ├── manul.db
│   ├── locks/
│   └── tasks/
├── logs/
└── workspace/
```

The runtime contains Manul configuration, SQLite state, logs, locks, task
artifacts, workspace state, runtime script links, and the operator environment
file `.env`. OpenClaw configuration/state remains outside that ownership
boundary. Provider-specific environment such as `OPENCLAW_STATE_DIR` or
`OPENCLAW_CONFIG_PATH` is persisted in `~/.manul/.env` when present during
installation/repair. Existing `.env` entries are preserved; arbitrary
environment variables are never copied. Unattended daemon/watchdog processes
load this file because cron/systemd does not load `~/.zshrc`.

## Agent execution boundary

The daemon never invokes an agent runtime directly. It calls
`AgentExecutionController.execute`, which routes through `AgentExecutor` to a
backend adapter selected by `AGENT_RUNTIME`:

```
Manul -> AgentExecutor -> OpenClawAdapter   (default)
                         -> OpenCodeAdapter
                         -> other adapters
```

Adapters are independent backends behind a single `ProcessRunner.run()`
process boundary. They must not spawn subprocesses directly and must not
depend on each other. Runtime-specific sessions and continuation mechanics
belong to the adapter, not to Manul task contracts.


## Task sources

The root work item is owned by a configured task source. GitHub Issues are the default source. Additional providers can be enabled in `.taskSources[]` and are polled independently.

PRs, review comments and CI checks are related development context, not task sources. A source can have multiple PRs attached to it.

Current provider types:

- `github_issues` — default, backed by GitHub repositories.
- `jira_tasks` — Jira REST provider, disabled by default.

See `task-source.sh` and `task-source-jira-tasks.sh` for the provider contract.
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

## Progress checkpoints

For non-trivial repository tasks, do not keep all meaningful work uncommitted
until the end. After each logically complete and valuable milestone, the agent
MUST create a checkpoint commit and push it before starting the next high-risk
investigation or implementation step.

A checkpoint can be a proven regression test, a verified root-cause fix, a
separately validated corrective change, or another meaningful recoverable state.
Checkpoints do not imply task completion.

For existing PR tasks, checkpoints MUST be pushed to the PR's existing head
branch. Always distinguish local/uncommitted changes from committed-but-
unpushed changes and from changes actually visible on the GitHub PR. After each
checkpoint push, verify the remote/PR head SHA.

When useful, leave a concise PR comment describing what the checkpoint
establishes and whether the overall task remains in progress. Preserve
already-pushed checkpoints across retries, timeouts, workspace loss, and
runtime failures. A runtime failure must not be treated as proof that no
progress was made.

## Unit test guidance

When a repository task adds or changes unit tests, read `UNIT_TESTING.md` before implementing the test. Treat it as the unit-testing methodology for Manul tasks, especially `REVIEW_FIX` work.

## User decision points

Routine ambiguity is resolved autonomously from repository conventions and available context. When a missing decision materially affects correctness, architecture, behavior, scope, compatibility, data model, UX, or another important outcome, the agent must stop rather than guess.

Before asking, inspect the repository, relevant skills/docs, configuration, and conversation context. The user-facing request must summarize what was checked, explain why the uncertainty is material, and present the concrete options or decision required; a recommendation is allowed, but the user's choice is authoritative.

Emit exactly one complete:

`TASK_NEEDS_USER_BEGIN`
<findings, options, recommendation if useful, explicit question/decision>
`TASK_NEEDS_USER_END`

Do not emit `TASK_DONE`, `TASK_COMPLETED`, or `TASK_FAILED` in the same execution output. After reaching the decision point, make no further irreversible repository changes. Manul records `blocked_user`, posts the request to the same GitHub conversation, and resumes the same task via `/manul continue <answer>`. Partial or malformed decision blocks are not valid pauses.

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

- `mode`: `bot` (default) or `human`;
- `commentStyle.human.concise` (default `true`) controls concise human-mode result comments;
- `commentStyle.human.maxLines` (default `6`) caps visible human-mode result-comment lines and is clamped to 1–20;

Human mode is intentionally a presentation/attribution mode: task state remains authoritative in SQLite and local logs, while GitHub receives only the user-facing agent result (and genuine user-decision questions when needed). When `commentStyle.human.concise` is enabled, that result should read like a short teammate reply and stay within the configured visible line limit, without automation-report headings or boilerplate.

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
- prepares the operator `.env` for unattended processes;
- configures required provider-owned OpenCode permissions when OpenCode is installed;
- prepares/validates the DB;
- installs the watchdog cron;
- installs the zsh shell integration.

For OpenCode, the installer/repair path ensures the provider-owned global configuration
contains `permission.external_directory["/tmp/**"] = "allow"` when an OpenCode
configuration is available. Existing OpenCode settings are preserved and no broad
permission bypass such as `--auto` is enabled. The provider configuration remains
outside `~/.manul`.

The operator `.env` is runtime-owned and mode 600. It carries only the
provider variables explicitly supported by the installer, such as custom
OpenClaw state/config paths.

The current installer deliberately does not start the daemon automatically.

The runtime isolation refactor has landed: the runtime is `~/.manul` and there is no migration path from obsolete `.openclaw/manul` state.

## Verification

Relevant test entry points include:

```bash
bash skills/manul-github-bot/test_runtime_health.sh
bash skills/manul-github-bot/test_agent_execution_smoke.sh
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
