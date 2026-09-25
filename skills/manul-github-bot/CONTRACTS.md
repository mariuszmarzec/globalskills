# Manul Contracts and Invariants

This document records behavioural contracts that should survive refactors. Implementation details may change; these semantics should not change accidentally.

## 1. GitHub command contract

Supported commands parsed from a `/manul` command are:

| Command | Action |
|---|---|
| `/manul run <task>` | `IMPLEMENT` |
| `/manul review-fix <prompt>` | `REVIEW_FIX` |
| `/manul continue <answer>` | resume a `blocked_user` task |
| `/manul verify <prompt>` | `VERIFY` |
| `/manul status` | query conversation status |
| `/manul close` | close a conversation |

Routine ambiguity should be resolved by the agent. User input is requested only for a materially important unresolved decision.

## 2. Task state contract

Core execution states are:

```
queued
  -> running
      -> completed
      -> failed
      -> blocked_user
      -> stale / requeued
```

A `blocked_user` task is terminal-for-now, not a failure. It remains associated with its existing conversation/task context and resumes through `/manul continue <answer>`.

A stale running task is either:
- requeued for another execution attempt, preserving its attempt count; or
- marked failed when the configured maximum attempts has been reached.

## 3. Attempt counting

`attempts` counts actual execution claims.

It increments only on:

```
queued -> running
```

Recovery:

```
running -> queued
```

does not increment attempts.

This prevents watchdog recovery from consuming retry budget by itself.

## 4. Worker ownership and leases

A running task is owned by its worker identity/claim token.

The daemon records and/or refreshes:
- `heartbeatAt`
- `leaseExpiresAt`
- `workerPid`
- `claimToken`

A recovery operation must verify ownership before changing a running task.

Heartbeat/lease recovery must never blindly reset a live task owned by another worker.

## 5. Single source of truth

`manul.db` is the authoritative task state.

Operational files such as:
- PID files;
- heartbeat PID files;
- logs;
- transient task stdout/stderr;
- result artifacts

must not become a second task-state database.

## 6. Concurrency

Task execution is serialized according to the configured concurrency limit.

The default configuration uses:

`maxConcurrentTasks = 1`

Repository locks prevent two tasks from concurrently modifying the same repository workspace.

A task lock/flock is a safety mechanism, not a replacement for SQLite ownership checks.

## 7. GitHub comment contract

Every Manul-signed comment ends with exactly one:

`— manul 🐈`

The signature is separated from the body by two newlines.

A result comment additionally contains an invisible deterministic marker:

`<!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->`

The daemon uses that marker to correlate the result to the exact task execution attempt.

## 8. Result-comment contract

For an agent execution:
- the agent must post exactly one user-facing result comment;
- the result comment must be posted before `TASK_DONE`;
- the comment must contain the exact task/attempt marker;
- lifecycle comments such as `🔄 working`, `✅ completed`, `❌ failed`, and retry notifications are separate daemon responsibilities.

A `TASK_DONE` without a verified result comment is not accepted as successful completion.

The daemon may verify the final PR identity and repository cleanliness before accepting completion.

## 9. Comment routing

Tasks originating from:
- an issue body;
- an issue/PR conversation comment

receive top-level result/lifecycle feedback on that issue/PR conversation.

Tasks originating from a PR review comment receive feedback as an in-thread reply to that review comment.

Cross-posting a review-thread task into a top-level PR comment is a routing bug.

## 10. Repository workflow

### Issue tasks

Manul first prepares an up-to-date isolated base workspace.

The agent decides whether the task is:
- informational; or
- a repository-change task.

Informational tasks:
- do not modify repository files;
- do not create a task branch;
- answer on GitHub and finish.

Repository-change tasks:
- create a dedicated task branch according to the feature/bugfix branching policy;
- never commit directly to a base/default branch;
- push the task branch;
- deliver changes through a real GitHub PR.

### PR review/conversation tasks

When a task comes from an existing PR review/conversation:
- reuse the PR's existing head branch;
- do not create a new unrelated branch;
- update the same PR.

## 11. PR identity

Issue numbers and PR numbers are independent.

A repository-change task is not successfully delivered until the PR has been verified as a real GitHub PR with:
- the expected head branch;
- the expected base branch;
- the concrete GitHub PR URL.

`/compare` and `/pull/new` links are not valid completion evidence.

## 12. Source revalidation

Before executing a queued task, Manul may revalidate that its GitHub source still exists and is active.

Examples:
- closed issue -> stale;
- closed PR -> stale;
- resolved/deleted review context -> stale.

A stale source is not treated as a successful task completion.

## 13. Workspace contract

Workspace preparation is part of Manul orchestration.

Workspaces must be isolated per active task and released after task completion/failure/recovery.

Workspace reclamation must use the same liveness/lease semantics as task recovery.

## 14. Watchdog contract

The watchdog is a liveness/recovery mechanism, not a general task scheduler.

It may:
- restart an enabled daemon that is not running;
- remove a stale daemon lock;
- reclaim stale workspaces;
- recover tasks whose heartbeat/lease is stale.

It must not:
- reset healthy running tasks;
- reset all tasks merely because a lock is old;
- create a second independent retry policy.

The daemon also performs a recovery pass at loop startup; this is a deliberate startup safeguard and not a competing retry mechanism.

## 15. User-decision contract

When the agent materially needs user input it must:
1. emit the structured needs-user block;
2. let Manul persist `blocked_user`;
3. stop treating that execution as success/failure;
4. resume the same task context after `/manul continue <answer>`.

Equivalent implementation choices should be resolved by the agent without blocking the user.

## 16. Configuration contract

The runtime reads Manul configuration from `MANUL_DIR/config.json`, where `MANUL_DIR` resolves to `~/.manul`.

The example configuration currently defines:
- polling interval;
- allowed users/repositories;
- agent names;
- PR automation;
- rebase behaviour;
- retry/context limits;
- CI-fix limits;
- agent timeout;
- heartbeat timeout;
- lease timeout;
- maximum attempts;
- lock TTL;
- maximum concurrent tasks.

The location of this configuration is `~/.manul/config.json`. The semantics of these controls should not change accidentally.

## 17. Runtime boundary

Manul task contracts are runtime-neutral. The daemon never invokes an agent
runtime directly; it calls `AgentExecutionController.execute`, which routes
through `AgentExecutor` to a backend adapter.

Adapters are independent backends behind a single `ProcessRunner.run()`
process boundary. OpenClaw (`openclaw-adapter.sh`) is the default runtime;
OpenCode (`opencode-adapter.sh`) is an independent alternative. Adapters must
not spawn subprocesses directly and must not depend on each other.

Runtime-specific details (sessions, continuation mechanics, tool paths) are
implementation details of the adapter, not Manul task contracts.

## 18. Clean-break policy

The runtime isolation refactor is a clean break from `~/.openclaw/manul`.

- `MANUL_DIR` resolves to `~/.manul`; there is no fallback and no
  `OPENCLAW_MANUL_DIR` alias.
- Old `~/.openclaw/manul` state or paths are not preserved or migrated.
- No compatibility shims keep obsolete runtime state working.

Behavioural compatibility is required; obsolete filesystem layout
compatibility is not.
