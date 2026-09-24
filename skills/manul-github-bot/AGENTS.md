# Agent Instructions for Manul

This file is the local guardrail for agents modifying `skills/manul-github-bot/`.

## Read before changing code

For any non-trivial change, read these files first:

1. `AGENTS.md`
2. `ARCHITECTURE.md`
3. `CONTRACTS.md`
4. `SKILL.md`
5. The specific scripts and tests involved in the change.

Treat `CONTRACTS.md` as the list of behavioural invariants. Treat `ARCHITECTURE.md` as the ownership and dependency model.

## Current master vs target architecture

The current master implementation still uses `~/.openclaw/manul` as its default runtime directory and invokes the OpenClaw `main` agent directly from the daemon.

The approved next architecture intentionally changes that:

- Manul-owned runtime/state moves to `~/.manul/`.
- OpenClaw becomes one execution backend behind an `AgentExecutor` adapter.
- Other agent runtimes can later be added without changing Manul task lifecycle.
- Native provider configuration remains owned by the provider.

The target architecture is **not implemented merely because it is documented here**. Keep documentation explicit about what is current and what is planned.

## No backward-compatibility requirement for the runtime refactor

For the upcoming runtime isolation and adapter work, do not preserve the old `~/.openclaw/manul` layout merely for compatibility.

A clean replacement is preferred over:

- dual runtime directories;
- fallback from `~/.manul` to `~/.openclaw/manul`;
- database migrations solely to preserve obsolete runtime state;
- compatibility aliases that couple Manul back to OpenClaw.

Existing behavioural contracts must still be preserved unless a change is intentional, documented, and tested.

## Core invariants

Do not accidentally break:

- SQLite as the authoritative Manul task state.
- Atomic task claiming and worker ownership.
- Heartbeat/lease recovery semantics.
- Attempt counting semantics.
- `blocked_user` as a resumable user-input state, not a failure.
- Deterministic task/attempt result markers.
- Exactly one user-facing result comment per agent attempt.
- Correct routing of top-level comments vs PR review-thread replies.
- Issue-task branch creation and PR requirements.
- Reuse of an existing PR head branch for PR review/conversation tasks.
- Source revalidation for stale/closed GitHub objects.
- Workspace/repository lock ownership.
- No direct task changes on a base/default branch.
- Existing GitHub control protocol and local CLI semantics.

## Responsibility boundaries

Manul owns:

- GitHub polling/control events;
- task queue and state;
- retries, leases and watchdog recovery;
- workspaces and repository locks;
- lifecycle/result verification;
- GitHub comments and PR delivery checks.

An agent runtime owns:

- the LLM/tool execution loop;
- runtime-specific sessions/context;
- runtime-specific continuation mechanics.

Do not move runtime-specific behaviour into the Manul core when an adapter can contain it.

## Coding and verification rules

Prefer small, surgical changes.

Before declaring success:

- run the relevant tests;
- run the broader Manul test suite when architecture or shared helpers change;
- inspect `git diff` and `git status`;
- never claim a test passed without actually running it.

Do not modify `manul.db` as part of repository changes.

Never put secrets, local credentials, or machine-specific state into the repository.

When changing a behavioural contract, update `CONTRACTS.md` in the same change and add/adjust tests that prove the new contract.

## Documentation truthfulness

Current-state documentation must describe the code that is actually on the current branch.

Planned architecture must be explicitly marked as planned/unimplemented.

Do not keep a statement in documentation merely because it was true in an older version of Manul.
