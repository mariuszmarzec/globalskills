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

A user-decision request is valid only when the agent emits exactly one:
`TASK_NEEDS_USER_BEGIN`
...
`TASK_NEEDS_USER_END`
block, with non-empty content between the markers and no `TASK_DONE`, `TASK_COMPLETED`, or `TASK_FAILED` marker in the same execution output. Malformed or partial blocks are treated as execution failures, not as `blocked_user`.

The decision content should summarize what the agent checked, explain why the remaining uncertainty materially affects correctness or outcome, and present the concrete options or decision required. The agent may recommend an option, but the user's decision remains authoritative. Once the decision point is reached, no further irreversible repository changes are allowed in that execution.

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
- if a comment with the exact marker already exists, the agent must update it in place instead of creating a duplicate;
- the final GitHub state must contain exactly one matching result comment for that task/attempt;
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

The agent execution boundary exposes only the task-owned workspace path (`WORKDIR`) to the agent as its repository working directory. Manul's internal repository preparation directory (`REPO_DIR`) is an orchestration detail and must not be included in the generated agent prompt. Git and file operations performed by the agent must stay inside `WORKDIR` unless the task explicitly requires an approved external dependency.

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

## 16. Human and bot modes

The top-level configuration key `mode` selects Manul's GitHub presentation/attribution behavior:

- `bot` is the default and preserves the existing Manul signature, lifecycle/status/error comments, and AI commit attribution.
- `human` suppresses Manul signatures and orchestration lifecycle/status/error comments on GitHub.
- In `human`, when `commentStyle.human.concise` is enabled, the visible result comment should be a short, natural teammate reply and stay within `commentStyle.human.maxLines`; automation-report headings and boilerplate should be avoided.
- In `human`, the agent's actual result comment remains user-facing and is verified using the invisible deterministic task/attempt marker.
- In `human`, commits must not contain an AI `Co-authored-by` trailer.
- Task state, recovery, leases, and local diagnostics remain unchanged; human mode is not a weaker execution or verification mode.

The mode is resolved from `MANUL_MODE` when explicitly provided, otherwise from `.mode`, defaulting to `bot`. Invalid values are rejected.

## 17. Configuration contract

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

The location of this configuration is `~/.manul/config.json`. Operator/provider
environment for unattended execution is stored separately in `~/.manul/.env`;
it is not part of the Manul JSON configuration contract. The semantics of
these controls should not change accidentally.

## 18. Runtime boundary

Manul task contracts are runtime-neutral. The daemon never invokes an agent
runtime directly; it calls `AgentExecutionController.execute`, which routes
through `AgentExecutor` to a backend adapter.

Adapters are independent backends behind a single `ProcessRunner.run()`
process boundary. OpenClaw (`openclaw-adapter.sh`) is the default runtime;
OpenCode (`opencode-adapter.sh`) is an independent alternative. Adapters must
not spawn subprocesses directly and must not depend on each other.

Runtime-specific details (sessions, continuation mechanics, tool paths) are
implementation details of the adapter, not Manul task contracts.

Every adapter failure result should preserve actionable diagnostics in its
`ExecutionResult` when the runtime provides them, including the runtime,
exit code, session ID, duration, error type/message, and the location of any
retained raw runtime log. A generic summary such as "agent exited with code 1"
is not sufficient when the runtime exposes a more specific error.

Per-attempt runtime logs are diagnostic artifacts, not task state. They should
be retained under the Manul task-log directory and cleaned by the normal task
retention policy.

## 19. Clean-break policy

The runtime isolation refactor is a clean break from `~/.openclaw/manul`.

- `MANUL_DIR` resolves to `~/.manul`; there is no fallback and no
  `OPENCLAW_MANUL_DIR` alias.
- Old `~/.openclaw/manul` state or paths are not preserved or migrated.
- No compatibility shims keep obsolete runtime state working.

Behavioural compatibility is required; obsolete filesystem layout
compatibility is not.


## 20. Task-source contract

Manul task sources are configured as `.taskSources[]`. Each enabled source is
an independent provider and is polled during the same cycle.

The provider contract is normalized to:
- `taskSourceType`
- `taskSourceId`
- `taskSourceUrl`
- title/body and timestamps
- provider-specific `metadata`

The task-source identity is the root work item. A pull request, review
comment, or CI check is never a task-source root. Those artifacts may be linked
as context to a task owned by another source.

The default source is `github_issues`. Existing configurations without
`.taskSources` fall back to the legacy `.repositories` array as one GitHub
Issues source.

Multiple enabled sources are independent: a failure in one provider must not
prevent other providers from being polled.

The initial non-GitHub provider is `jira_tasks`. Its current provider endpoint is configurable (default `/rest/api/2/search`).
Tasks are selected by the configured Manul trigger in the Jira description.
Authentication uses the environment variables named by `userEnv` and
`passwordEnv` (defaults `MANUL_JIRA_USER` and `MANUL_JIRA_PASSWORD`), never
stored in JSON configuration. The provider is disabled by default.

## 21. Unit-test contract

When an implementation task adds or changes unit tests:
- tests must prove the requested behavior, not merely object construction, helper execution, DTO conversion, or property structure;
- the test should execute the real production entry point containing the behavior under test;
- external dependencies may be mocked, but the system under test must remain real;
- interaction-based behavior must be asserted through the real dependency boundary with the requested calls and arguments;
- a test is invalid if it would still pass after the requested production behavior is removed;
- when an existing relevant unit test or test file exists, extend or modify it rather than creating a parallel duplicate unless there is a concrete reason;
- when a review comment names a test location, treat that location as part of the acceptance criteria;
- test-framework or mocking difficulties must not be solved by weakening or removing the behavioral assertion;
- if the intended behavioral test remains blocked after reasonable investigation, use `TASK_NEEDS_USER` when a material design choice is required rather than silently lowering test quality;
- compilation alone is not evidence that the requested behavior is covered.

For `REVIEW_FIX`, the review comment's requested production call, side effect, interaction, or verification is authoritative. Implementation details may differ, but the behavioral contract must remain intact.

## 21. Deployment and executable-entry-point contract

Runtime entry points that Manul invokes directly must remain executable in the canonical checkout. In particular, `agent-task-runner.sh` is launched directly by `setsid` and therefore requires the Git executable mode `100755`. Sourced helper scripts do not require the execute bit. The runtime installer/startup path must preserve or restore the execute bit, and CI must fail when the canonical runner loses it.
## 22. Progress checkpoint contract

For non-trivial repository-change tasks, the agent MUST NOT accumulate all
meaningful work as uncommitted workspace state until the end. After each
logically complete and meaningful milestone, it MUST create a checkpoint commit
and push it to the task branch/PR branch, together with a concise status comment
when useful.

A milestone may include, for example:
- a reproducible regression test that captures the original failure;
- a proven root-cause fix with focused tests passing;
- a separately verified corrective change;
- a regenerated artifact/snapshot after its inputs are known to be correct.

Checkpoint commits are valid even when the overall task is not complete. A checkpoint must not be presented as final completion unless all task acceptance criteria are satisfied.

For existing PR tasks, checkpoint commits must be pushed to the PR's existing head branch. For standalone repository-change tasks, checkpoint commits must be pushed to the task branch.

Workspace-only changes are not considered delivered progress. The agent should distinguish explicitly between:
- local/uncommitted progress;
- committed but unpushed progress;
- pushed progress visible on the GitHub PR.

When a meaningful milestone has been reached, the agent MUST commit and
push it before starting a new high-risk investigation or implementation step.
After the push, the agent MUST verify that the remote branch (and existing PR,
when applicable) points at the pushed commit.

A failed or blocked execution MUST preserve already-pushed checkpoints and,
when safely possible, continue from the latest verified checkpoint rather than
restarting from the original task state. Runtime/LLM failure is not evidence
that repository work made no progress.


## 23. Delivery verification and failure classification

For repository-changing tasks, `TASK_DONE` is not sufficient evidence of delivery. The daemon must distinguish implementation completion from delivery completion and verify the repository/PR state before marking the task `completed`.

For a changed repository the delivery checks are:

1. The agent is on the expected task/PR branch.
2. The working tree has no staged, unstaged, or relevant untracked changes.
3. The changes are committed.
4. When an `origin` remote is available, the task branch exists on `origin` and its SHA matches the local `HEAD`.
5. For an existing PR task, the GitHub PR head branch and head SHA match the expected branch and delivered commit.

Failure codes must be stable and actionable:

- `RUNTIME_PERMISSION_BLOCKED` — runtime rejected a tool call because of a permission boundary.
- `PROVIDER_ERROR` — provider returned a structured runtime/provider error.
- `RUNTIME_FAILURE` — generic runtime execution failure.
- `RUNTIME_TIMEOUT` — runtime execution timed out.
- `TASK_NEEDS_USER` — structured user decision is required.
- `NEEDS_CONTINUATION` — runtime can continue an existing session.
- `DELIVERY_NOT_COMMITTED` — repository changes remain uncommitted when the agent reports completion.
- `DELIVERY_NOT_PUSHED` — committed work is not present on the remote/PR head.
- `WORKSPACE_DIRTY` — workspace contains unexpected residue that is not the agent's intended repository change.
- `VERIFICATION_FAILED` — branch, PR identity, or another required invariant could not be verified.
- `CONTROLLER_ERROR` — execution controller could not construct/return a valid execution result.

A final `completed` state requires the applicable verification checks to pass; a failure classification must not be overwritten by a later generic workspace check.
