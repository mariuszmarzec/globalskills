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
task ID and description. Do not use an unrelated operator Todo connection.

For Fiteo/Todo Remote, use only the Manul-owned MCP namespace and dedicated
Manul identity (in OpenCode: `manul_fiteo_todo_create_task`). Create a root
task with `parentTaskId: null`, the `/manul run` trigger and repository
reference, and the configured share recipient with `EDITOR_AND_VIEWER`
permission when required. Never use the operator PAT or raw operator Fiteo
MCP tool. If credentials, share identity or tools are unavailable, fail
closed; never create an unshared or untracked task.

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
  "status": "active",
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
        "status": "planned",
        "trackerRefs": []
      }
    ],
    "decisions": [],
    "assumptions": []
  }
}
MANUL_WORKFLOW_STATE_END
```

Valid statuses are `active`, `waiting_human`, `blocked` and `completed`.
Use phases that describe actual work, such as `discovery`, `planning`,
`dispatching`, `implementation`, `review`, `qa` and `delivery`. Keep
non-secret data only. Verify all external evidence before marking completed.
