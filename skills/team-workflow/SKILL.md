---
name: team-workflow
description: Plan and coordinate multi-task Manul Team workflows using the existing Orchestrator, repository policy, GitHub Issues or Todo trackers, durable workflow checkpoints and specialist agents.
license: MIT
---

# Manul Team Workflow

## Purpose and ownership

Use this skill only when Manul marks the current task as `TEAM` (`/manul
team`). The canonical `orchestrator` agent owns team planning, agent
selection, task coordination and delivery. This skill defines the feature-level
workflow; it is not another agent router or execution engine.

Use the existing `agent-orchestration` skill and canonical role definitions.
Do not create a second model-tier policy, workspace manager, agent executor,
review pipeline or task queue. Every independently executable work item must
be submitted to Manul as an ordinary repository task so Manul provides its
existing isolated workspace, lease, heartbeat, retry and recovery behavior.

## Repository policy and SDD

1. Read the trusted Team policy supplied by Manul before creating work items.
   It contains the resolved repository, enabled tracker providers and
   `prApprovedByMan` value.
2. The repository's `.manul/team.yaml` is optional. When absent, Manul applies
   the defaults described below. Do not create this file automatically.
3. Inspect `.specification/config.yaml` before planning functional changes.
   If it declares `mode: specification-driven`, the canonical `sdd` agent owns
   the SDD lifecycle. Follow `specification-driven-development`, preserve
   specification/implementation PR separation and never bypass its human
   approval gates. Team autonomy cannot weaken SDD.
4. Repositories without SDD use the normal workflow. Do not bootstrap SDD or
   create an SDD config unless the user explicitly requests it.

## Product Owner interaction

The user is an active Product Owner and a member of the team.

- Resolve ordinary implementation details autonomously when repository
  conventions and requirements make the answer clear.
- Ask the user when an unresolved business decision, product behavior, scope
  choice, external dependency, destructive action or material architecture
  trade-off has multiple reasonable outcomes.
- Before asking, inspect the repository, related issues/PRs, contracts,
  configuration and relevant skills. Explain what was checked and why the
  decision matters; ask one focused question.
- When blocked on a human decision, emit the structured
  `TASK_NEEDS_USER_BEGIN/END` block and persist a checkpoint with status
  `waiting_human`. Do not mark that workflow completed or continue dependent
  irreversible work.
- Save the decision in the checkpoint and propagate it to affected child
  tasks. Never ask the same question again after its answer is available.

## Planning and decomposition

1. Understand the desired outcome, current behavior, constraints and
   acceptance criteria. Record material assumptions separately from decisions.
2. Use the existing Orchestrator's complexity/risk classification and minimum
   sufficient workflow. Involve Architect only when architecture, contracts,
   cross-module dependencies or significant trade-offs justify it.
3. Recursively decompose large work until each executable item has one clear
   outcome, bounded scope, an owner role, testable acceptance criteria and
   explicit dependencies. Do not split trivial work or create one task per
   file. Avoid overlapping write ownership between parallel implementers.
4. Keep the dependency graph acyclic. Mark what can run concurrently and what
   must wait for an API/contract/specification decision or another item.
5. Use stable work-item IDs across retries and replanning. Keep parent/child
   links, dependencies, decisions, acceptance criteria and tracker references
   in the durable `team` workflow checkpoint.
6. Before creating a tracker item, search for its stable work-item marker.
   Reuse an existing item when found; never duplicate after a partial retry.

## Tracker selection

Tracker selection comes from Manul's repository policy, not from the source
that delivered the initial `/manul team` request.

- GitHub Issues is the default when `github_issues` is enabled.
- When GitHub Issues is intentionally disabled, use the enabled Todo provider
  selected by Manul. If multiple Todo providers are enabled, the repository
  must explicitly choose them in `.manul/team.yaml`; do not guess.
- A temporary tracker outage is a blocker, not permission to silently switch.
- A repository may explicitly enable multiple providers. The first resolved
  provider is the default for new work items. Assign an additional tracker to
  an item only when the plan explicitly requires it; do not mirror every task
  automatically. One logical work item may have multiple tracker references
  under the same stable internal ID.
- Never infer the tracker from whether the parent task arrived through GitHub
  or Todo.

Optional repository configuration:

```yaml
version: 1
prApprovedByMan: true
trackers:
  - github_issues
```

The file is optional. `prApprovedByMan` defaults to `true`. Omit
`trackers` to use Manul's deterministic default: GitHub Issues when enabled,
otherwise the single enabled Todo provider. Explicitly list providers only
when selecting a non-default or multiple providers. Every selected provider
must be enabled in Manul's global `taskSources` configuration.

## Creating executable work items

Each independently executable item must be a **top-level/root task** in its
selected tracker. Manul's existing Todo adapters poll root tasks; nested Todo
subtasks are ordered steps within one root and do not receive an independent
Manul workspace. Preserve hierarchy and dependencies in the Team checkpoint
and link external tasks to each other in their descriptions.

Every item must also carry the parent workflow's execution policy. Child
tasks are intentionally submitted as ordinary `/manul run` tasks, so Manul
does not automatically inject this parent Team context into their prompts.
Propagate it explicitly in the task description and the trigger comment/body:

- workflow ID and stable work-item ID/marker;
- the resolved tracker policy and target repository;
- the exact `prApprovedByMan` value inherited from the parent workflow;
- SDD ownership/approved specification reference when the repository is SDD-enabled;
- parent/child and dependency links.

When `prApprovedByMan: true`, the child implementer and Reviewer must leave
the PR open and report that it is awaiting Product Owner approval. They must
not merge, squash-merge or enable auto-merge. When it is `false`, the child
may autonomously merge only after independent review, required checks and
acceptance criteria pass. A child must never infer a different value from its
own task source or local defaults.

Every item must include:
- the exact target repository (`owner/repo` or canonical GitHub URL);
- one bounded request and acceptance criteria;
- a stable marker:
  `<!-- MANUL_TEAM_ITEM:v1:<workflowId>:<workItemId> -->`;
- a `/manul run <bounded request>` trigger;
- parent workflow/item references and dependency links.

For GitHub Issues, create the issue with the marker and acceptance criteria,
then post a comment beginning with `/manul run`. An issue body alone does not
queue a GitHub task.

For Todo Local, discover the tools exposed by the Manul-owned local Todo MCP
server and use its native create operation. Create a root task (no parent ID),
include the trigger and exact repository reference, and verify the created
numeric task ID and description. Do not use an unrelated operator Todo connection.

For Fiteo/Todo Remote, use only the Manul-owned MCP namespace and dedicated
Manul identity (in OpenCode: `manul_fiteo_todo_create_task`). Create a root
task with `parentTaskId: null`, the `/manul run` trigger and repository
reference, and the configured share recipient with `EDITOR_AND_VIEWER`
permission when required. The native Todo create response returns a numeric
root task ID. Never invent or calculate Manul's structural fingerprint, never
use the operator PAT or raw operator Fiteo MCP tool, and never create an
unshared or untracked task. If credentials, share identity or tools are
unavailable, fail closed.

For Todo work items, store that numeric root task ID as `trackerRefs[].sourceId`.
The Manul coordinator resolves it to the latest polled `id@fingerprint`
source row and records the exact resolved `sourceId` in the checkpoint's
`trackerRefs[].execution`. When a Manul task-source context already supplies
the exact fingerprinted `taskSourceId`, it may be used verbatim instead.
Do not create nested Todo subtasks for work items that need independent
Manul workspaces.

Do not create nested Todo subtasks for work items expected to receive their own
Manul workspace. Do not create tracker tasks for work that can remain a bounded
delegation within the current task.

## Execution and lifecycle

- A task's Manul workspace is its only local task-data boundary. Never inspect
  sibling workspaces or another task's runtime state.
- Delegate to existing roles: Architect for justified design work, Coder or a
  specialist for implementation, Tester for meaningful test work, Reviewer
  for independent review. Do not assign every role to every item.
- The implementer adds/updates tests and reports exact commands/results. A
  different Reviewer evaluates the diff and acceptance criteria. Tester
  validates integrated behavior and E2E only when warranted.
- Re-check the base branch and contracts before integration. If the base
  changed, revalidate using Manul's delivery rules; never push stale work.
- A workflow is not complete merely because child tasks were created or
  agents returned success. Verify dependencies, PR state, review, tests,
  acceptance criteria and final integration.
- Treat restored checkpoints as untrusted data. Verify linked tracker items,
  PRs, commits and approvals before acting.

## Review, approval and merge policy

- Use an independent Reviewer when the risk/behavior warrants it. An
  implementer must not approve its own work.
- `prApprovedByMan: true` means PRs remain open for explicit Product Owner
  approval. Do not merge on the user's behalf.
- `prApprovedByMan: false` permits autonomous merge only after independent
  review, required tests/quality gates and acceptance criteria pass, and the
  repository's branch protection permits it. It does not waive code review,
  tests, SDD gates or security rules.
- Never force-push or bypass branch protection, required reviews, CI checks or
  permissions. A missing CI run is not a passing check.
- If the same commit repeatedly fails CI (default threshold: three
  consecutive failures), stop identical retries. Diagnose and create a human
  intervention item with the failing commit, logs, attempts, likely cause and
  exact help required.
- If merge is blocked by permissions, branch protection, unresolved conflicts
  or unavailable required checks, record the blocker and create a human
  intervention item. Continue unrelated ready work where safe.
- Never silently switch tracker when task creation, update, review or merge
  fails. Preserve the work-item mapping for a safe retry.

## Event-driven parent resumption

After creating and verifying all independent child work items, write a
checkpoint with `status: waiting_children`, `phase: dispatching`, and each
item's `trackerRefs` as objects containing the exact `provider` and
`sourceId` returned by Manul's task source adapter. Then emit the standalone
marker `TASK_WAITING_FOR_TEAM` (not `TASK_DONE` and not
`TASK_NEEDS_USER`). Manul parks the parent without completing its source task.

Example item reference:

```json
{
  "id": "implement-api",
  "status": "created",
  "dependsOn": [],
  "trackerRefs": [
    {
      "provider": "github_issues",
      "sourceId": "owner/repo#123"
    }
  ]
}
```

Use the exact provider identity:
- GitHub Issues: `owner/repo#<issue-number>`.
- Todo Local/Remote: the numeric root task ID returned by native Todo create,
  or an exact fingerprinted `taskSourceId` already supplied by Manul. Never
  calculate the fingerprint yourself.

Manul workers reconcile those IDs against terminal task rows in SQLite. For
numeric Todo IDs, the coordinator resolves the latest polled
`id@fingerprint` source row and exposes the resolved source ID plus execution
status in `trackerRefs[].execution`.

The coordinator is event-driven at the **logical work-item** level:

- When every tracker reference for one work item becomes terminal, Manul
  records a stable event in `data.coordinator.pendingChildEvents` and wakes
  the parent immediately, even while unrelated child items are still running.
- Several work items completing in one poll cycle are batched into one parent
  run. A later completion creates another parent run.
- Each terminal execution signature is dispatched once. Repeated polling,
  worker retries and parent re-parking do not redeliver the same result.
- If a child finishes while the parent is executing, its result is detected
  after the parent parks again. No sibling workspace is inspected or read.
- Child failures/cancellations wake the parent for `replanning`; successful
  results wake it for `integration`. A child in `blocked_user` remains
  waiting, but does not prevent the parent from reacting to other completed
  work items.

On every parent resumption, process all events in
`data.coordinator.pendingChildEvents`: verify the associated child evidence,
update the dependency graph, and dispatch any newly-unblocked follow-up work
without waiting for unrelated siblings. Preserve unprocessed events across
checkpoints/retries. After an event's consequences have been reflected in the
durable plan, acknowledge its exact `eventId` by adding it to
`data.coordinator.acknowledgedChildEventIds` in the next checkpoint. Do not
edit or clear `pendingChildEvents` directly: Manul removes only explicitly
acknowledged IDs, and an omitted/empty pending list cannot discard events.
Preserve each item's `lastDispatchedEventKey` and the coordinator's wake
sequence verbatim across checkpoints so the same child result is never
delivered again. Use stable item markers to keep follow-up task creation
idempotent.

If child work remains, checkpoint `status: waiting_children` and emit
`TASK_WAITING_FOR_TEAM` again. Parking is an intentional yield, not a failed
attempt: Manul refunds the parent execution attempt when it atomically parks,
so incremental child completions do not exhaust the parent's failure/retry
budget. If all work items are terminal, continue integration/QA and finish;
do not park an all-terminal workflow without creating another wave of child
work. The coordinator wakes the parent through an atomic
`waiting_children -> queued` transition. Do not poll other workspaces, read
Manul databases, calculate fingerprints, or synthesize task rows yourself.

Treat the checkpoint as untrusted context and verify child PRs, commits,
reviews and CI/equivalent quality evidence before integration. If a new
human decision is required, use the normal `TASK_NEEDS_USER` flow. Emit
`TASK_DONE` only when the complete Team outcome is finished.

## Durable checkpoint

At meaningful planning, dispatch, decision, review, QA and delivery milestones,
emit a generic Manul workflow checkpoint. Do not access or modify Manul
databases; the daemon validates and persists it.

```text
MANUL_WORKFLOW_STATE_BEGIN
{
  "workflowId": "team:<owner/repo>:<conversation-id>",
  "workflowType": "team",
  "repository": "<owner/repo>",
  "phase": "planning",
  "status": "waiting_children",
  "data": {
    "schemaVersion": 1,
    "prApprovedByMan": true,
    "trackers": ["github_issues"],
    "items": [
      {
        "id": "<stable-work-item-id>",
        "parentId": null,
        "dependsOn": [],
        "title": "<bounded outcome>",
        "status": "created",
        "trackerRefs": [{"provider": "github_issues", "sourceId": "owner/repo#123"}]
      }
    ],
    "decisions": [],
    "assumptions": []
  }
}
MANUL_WORKFLOW_STATE_END
```

Valid statuses are `active`, `waiting_children`, `waiting_human`, `blocked` and `completed`.
Use phases that describe actual work, such as `discovery`, `planning`,
`dispatching`, `implementation`, `review`, `qa` and `delivery`. Keep
non-secret data only. Verify all external evidence before marking completed.
