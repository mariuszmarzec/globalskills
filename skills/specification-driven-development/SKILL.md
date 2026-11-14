---
name: specification-driven-development
description: Run a specification-first product change lifecycle. Use when initializing SDD explicitly, updating approved requirements, coordinating human approval gates, or handing approved requirements to implementation agents.
---

# Specification-Driven Development

## Purpose and authority

The approved specification is the product contract. The implementation is
expected to conform to it; existing code is evidence of current behavior, not
proof of desired behavior.

This skill defines the workflow. The `sdd` agent owns the workflow and may
delegate bounded work to the existing Globalskills Orchestrator. Do not create
a parallel agent router, model-tier system, or review pipeline.

## Activation and commands

SDD is opt-in per repository through `/.specification/config.yaml`.

- No config means the repository is **not** SDD. Do not create a config,
  bootstrap, or route the task into SDD unless the user explicitly asks to
  initialize it.
- `sdd bootstrap` is the only initialization path. It must be explicitly
  requested by the human.
- A normal SDD request requires a valid config. If absent or invalid, stop
  without code changes and explain how to invoke the explicit bootstrap.
- After bootstrap, the config becomes effective only when the Baseline PR
  containing it is approved and merged into the repository's target branch.
- A valid SDD config makes specification approval mandatory for functional
  behavior changes, regardless of whether the original request was phrased as
  a normal task or explicitly addressed to a coding role.

Suggested Manul forms:

```text
/manul sdd bootstrap
/manul sdd Add support for another ingredient unit
```

The same modes apply when the agent is invoked directly from local OpenCode.

## Modes

### Bootstrap

Use only after an explicit bootstrap request.

1. Inspect the repository's source, tests, configuration, integrations, and
   existing product documentation.
2. Inventory the existing specification and identify gaps, stale statements,
   contradictions, and undocumented behavior.
3. Separate:
   - **Current behavior** — what the code demonstrably does today.
   - **Desired behavior** — what the product should do.
   - **Unresolved decision** — what cannot safely be inferred.
4. Treat code as evidence, never as the authority for desired behavior. Do not
   silently turn a bug or accidental implementation detail into a requirement.
5. Delegate focused codebase discovery or design analysis to the existing
   Orchestrator (which may use Architect or Researcher). Ask the human about
   materially ambiguous product decisions using the host's supported
   human-in-the-loop mechanism.
6. Prepare a Baseline PR containing the initial specification, requirement
   IDs, glossary/decisions where useful, and `/.specification/config.yaml`.
   Do not include product-code changes.
7. Clearly label assumptions and unresolved items. Do not claim SDD is active
   until the Baseline PR is merged.

### Specification change

For every functional behavior request in an initialized SDD repository:

1. Read and validate `/.specification/config.yaml`.
2. Inspect the relevant approved requirements and decisions, then inspect
   current code/tests to understand current behavior and impact.
3. Clarify desired behavior with the human where a material product decision
   cannot be resolved from the request and approved specification.
4. Delegate bounded architectural or discovery tasks to the existing
   Orchestrator. Use `workflow_owner: sdd` in delegated task context so the
   Orchestrator does not recursively route its own child task back to SDD.
5. Draft requirement changes with stable IDs and testable acceptance
   criteria. Prefer modifying the smallest relevant specification documents.
6. Open a **Specification PR only**. It may change requirement documents,
   decisions, examples, and specification metadata. It must not implement
   product code or modify tests as a substitute for approving behavior.
7. Wait for explicit human approval and merge. A PR being opened, an AI
   reviewer passing, or a GitHub status check passing is not human approval.
8. Record the resulting approved specification commit SHA. This immutable
   SHA is the contract for the implementation stage.

### Implementation

Only after the Specification PR is merged:

1. Create a distinct implementation task/branch/PR. Link it to the source
   request, Specification PR, approved specification commit, and requirement
   IDs.
2. Delegate implementation through the existing Orchestrator. It selects
   the appropriate Architect/Coder/Tester/Reviewer roles and model tiers
   according to the existing orchestration policy.
3. The Coder implements only the approved requirement scope. If implementation
   reveals a material behavior ambiguity or a required behavior change outside
   the approved scope, stop and return to the specification stage. Do not
   quietly amend requirements to fit the code.
4. Verify each acceptance criterion with tests or other concrete evidence.
5. Have the existing review workflow check both code quality and conformance
   to the approved requirements. Do not add a duplicate review pipeline merely
   because SDD is active.
6. The Implementation PR must include a requirement-to-implementation-to-test
   coverage table, the approved spec commit SHA, verification results, and
   any justified limitations.
7. Keep the implementation PR separate from the Specification PR. Human
   acceptance of the implementation remains the final delivery gate.

## Requirement format

Each requirement should have a stable identifier, a concise normative
statement, rationale/context where useful, and verifiable acceptance criteria.

Recommended pattern:

```markdown
### REQ-<DOMAIN>-NNN — <short name>

**Requirement**

The system MUST ...

**Rationale**

Why this behavior is needed, without repeating the requirement.

**Acceptance criteria**

- Given ..., when ..., then ...
- Boundary/edge case ...
- Regression expectation ...

**Verification**

- Test or observable evidence that demonstrates each criterion.
```

IDs must remain stable when wording changes. Retire obsolete IDs explicitly;
do not silently reuse them.

## Repository configuration

Bootstrap should create this minimal, forward-compatible file:

```yaml
version: 1
mode: specification-driven

specification:
  root: .specification
  requirements: .specification/specs
  decisions: .specification/decisions

policy:
  functional_changes_require_approved_specification: true
  implementation_requires_requirement_ids: true
```

No config means no SDD. Unknown versions, malformed YAML, unsupported modes,
or contradictory policy values must fail closed in automated routing.

## Persistence and resumption

Do not rely on a particular LLM session, agent memory, or runtime session ID
as the source of truth.

Persist workflow milestones through durable artifacts and references:
- source issue/task and conversation identity;
- workflow ID and current phase;
- Baseline/Specification/Implementation PR identities;
- approved specification commit SHA;
- requirement IDs and implementation task/PR identities;
- human decisions and outstanding blockers;
- completed phase results and verification evidence.

Manul may additionally index these in its own workflow store. Git history,
merged PRs and specification documents remain the portable source of truth so
local OpenCode can resume the same process without depending on Manul's DB.

When resuming after interruption, reload the repository policy and the latest
approved commit/PR state before acting. Never assume that an earlier agent
session or an unmerged local draft is authoritative.

## Delegation contract

When calling the existing Orchestrator for a bounded subtask, include:

```yaml
workflow_owner: sdd
workflow_id: <stable-id>
workflow_phase: discovery | implementation | review
approved_specification_commit: <sha-or-null>
requirement_ids:
  - REQ-...
```

The Orchestrator should keep its existing classification, model selection,
role delegation, verification, and escalation behavior. It must not perform
functional implementation before the approved specification gate is passed.

## Human-in-the-loop rules

- The human approves product behavior in the Specification PR.
- The human accepts the delivered implementation in the Implementation PR.
- Agents may recommend and explain, but may not approve on the human's behalf.
- If blocked waiting for a decision, preserve progress and use the host
  runtime's resumable user-input mechanism.
- Never report completion while an approval gate or a material decision is
  pending.

## Scope exclusions

SDD does not prescribe a programming language, framework, agent runtime,
model provider, GitHub client, or test framework. It does not replace
repository-specific architecture, coding, security, or review guidance.
