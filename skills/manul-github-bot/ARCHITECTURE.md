# Manul Architecture

## Purpose

Manul is a GitHub task orchestrator. GitHub comments create tasks; Manul persists task state, prepares isolated repository workspaces, invokes an agent runtime, verifies the result, and delivers the result through GitHub.

This document distinguishes the **current master baseline** from the **approved target architecture** for the next refactor.

## Current master baseline

```
GitHub
  |
  +--> poll.sh / GitHub control scripts
            |
            v
        SQLite manul.db
            |
            v
       manul-daemon.sh
            |
            +--> workspace-manager.sh
            |
            +--> agent execution
                    |
                    v
              OpenClaw main agent
                    |
                    v
                 agent/tools
```

The current daemon invokes the OpenClaw `main` agent directly. OpenClaw currently provides the agent execution environment used by Manul.

### Current source/runtime split

Canonical source:

`~/.globalskills/skills/manul-github-bot/`

Current default runtime:

`~/.openclaw/manul/`

The installer currently deploys the runtime scripts as symlinks from the canonical skill directory and keeps runtime data such as the SQLite DB, logs, locks and task files in the runtime directory.

Current default path selection is implemented through `MANUL_DIR`; some older helper scripts still accept `OPENCLAW_MANUL_DIR` as an alias. That coupling is an implementation detail to remove during runtime isolation.

### Current runtime ownership

Current master effectively treats these as Manul runtime data under `MANUL_DIR`:

- `config.json`
- `manul.db`
- logs
- lock files
- task/prompt/output artifacts
- repository locks
- workspace pool/worktrees
- runtime script links

OpenClaw configuration/state remains outside that ownership boundary.

## Task execution plane

```
queued
  |
  v
running
  |
  +--> completed
  |
  +--> failed
  |
  +--> blocked_user
  |
  +--> stale / requeued
```

The daemon claims queued tasks, assigns worker ownership, starts a heartbeat, executes the agent, verifies the execution result, and performs terminal state transitions.

SQLite is the authoritative task state. Files such as logs, PID markers and transient execution output are operational artifacts, not alternative sources of truth.

## Reliability plane

```
manul-daemon
  |
  +--> per-task heartbeat
  +--> lease expiry
  +--> startup stale-task recovery
  |
  +--> watchdog (periodic liveness/recovery)
```

The daemon performs a stale-task recovery pass when its loop starts. The watchdog is the periodic liveness mechanism: it can restart an enabled daemon, remove a stale daemon lock, reclaim stale workspaces, and recover tasks using heartbeat/lease ownership checks.

The watchdog must not blindly reset task state.

## GitHub control plane

The GitHub control scripts provide:

- command parsing for `/manul`;
- issue/PR/review event handling;
- conversation linking;
- result feedback;
- source revalidation.

The machine-readable protocol is documented in `GITHUB_CONTROL_PROTOCOL.md`.

## External orchestration plane

`manul-orchestrator.sh` is a separate local control layer. It persists its own conversation/review orchestration state in `orchestrator.db` under `ORCHESTRATOR_DIR`.

It submits and observes tasks through the Manul task system; it is not the core daemon and does not replace `manul.db`.

```
External caller
    |
    v
manul-orchestrator.sh
    |
    +--> manul-conversation / submit / wait / result
    |
    v
Manul task system
    |
    v
GitHub
```

## Approved target architecture

The next refactor will make Manul independent of the OpenClaw runtime layout:

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

OpenClaw remains provider-owned:

```
~/.openclaw/
```

OpenCode, Claude Code, Tabnine and other runtimes retain their native configuration/state locations unless an adapter has a concrete reason to own additional Manul-specific data.

The execution boundary becomes:

```
Manul daemon
     |
     v
AgentExecutor
     |
     +--> OpenClawAdapter
     |
     +--> OpenCodeAdapter
     |
     +--> other adapters
```

Manul should own **task lifecycle and scheduling**.

The runtime should own **agent execution and its own loop/session semantics**.

The first implementation will add the abstraction and an OpenClaw adapter. OpenCode continuation/step-limit handling belongs in a later adapter/controller change.

## Ownership rule

A useful test for any new piece of state is:

> Who conceptually owns this state?

If it is required to schedule, recover, observe or coordinate Manul tasks, it belongs to Manul.

If it is required only to run one specific agent runtime, it belongs to that runtime or its adapter.

## Migration policy

The new runtime architecture is intentionally a clean break.

There is no requirement to migrate old `~/.openclaw/manul` state into `~/.manul`. The migration work may remove obsolete paths and compatibility fallbacks rather than preserve them.

Until the runtime-isolation code lands, however, the current master baseline remains the source of truth for actual commands and paths.
