---
name: review-strategy
description: Shared methodology for high-quality code review. Defines how reviewers understand requirements, inspect implementation, test behavior, identify risks, and produce evidence-based findings.
---

# Review Strategy

## Core Principle

The goal of a code review is NOT to find the largest possible number of issues.
The goal is to:
* understand what the user actually requested,
* verify that the implementation satisfies the requirements,
* find real correctness issues,
* find meaningful edge cases and failure modes,
* evaluate test coverage,
* minimize false positives,
* avoid stylistic noise.

Core principle:
A technically clean implementation that does not satisfy the requirement is still incorrect.
A reviewer must not assume that well-written code and passing tests mean that the task was implemented correctly.

## Requirements First

Requirements are the first stage of the review.
Before analyzing the implementation, establish:
* what the user wants to achieve,
* expected behavior,
* explicit requirements,
* acceptance criteria,
* constraints,
* what the implementation should NOT do,
* what is explicitly out of scope, when this can be determined.

Requirements may come from:
* the user request,
* task/ticket,
* specification,
* acceptance criteria,
* existing documentation,
* explicit constraints provided to the agent.

Do not invent missing requirements.
If requirements are ambiguous or incomplete, identify the uncertainty and use available context to determine the most justified interpretation.
If expected behavior cannot be established reliably, do not pretend to have certainty.

## Requirements → Behavior → Implementation

The reviewer must explicitly reason through:
```text
Requirements
     ↓
Expected behavior
     ↓
Actual implementation
     ↓
Tests
```

For every important requirement, check:
1. Does the implementation satisfy the requirement?
2. Does it satisfy it completely?
3. Is any part implemented incorrectly or only partially?
4. Does the implementation introduce behavior that conflicts with the requirement?
5. Does it unintentionally change existing behavior?
6. Do the tests actually prove the required behavior?

Example:
Requirement: "User can manually retry a failed upload."
Implementation: "Upload automatically retries three times."
Do NOT consider this correct merely because retry technically works. This is a requirements violation.

## Requirements Priority

Use this hierarchy when determining the intended behavior:
1. Explicit current user requirement
2. Explicit acceptance criteria/specification
3. Explicit project constraints
4. Existing architecture/conventions
5. Reasonable inference from surrounding code

Existing code or preferred architecture must not override an explicit requirement.
If the requirement conflicts with the existing architecture:
* do not silently ignore the requirement,
* identify the conflict,
* determine whether the implementation actually satisfies the requirement.

## Scope Control

Review whether the implementation does substantially more than the task requires.
Look for:
* unrelated behavior changes,
* unnecessary side effects,
* unnecessary public API changes,
* unnecessary dependency changes,
* scope expansion,
* changes to existing behavior unrelated to the task.

Do NOT treat every additional refactor as a defect.
Report it only when it:
* increases meaningful risk,
* violates requirements,
* introduces a regression,
* unnecessarily complicates the solution,
* or creates a significant maintainability problem.

## Review Process

After requirements analysis, perform the review in this order:
1. Understand requirements
2. Define expected behavior
3. Identify behavioral surface
4. Read the implementation diff
5. Read surrounding code where necessary
6. Compare implementation against requirements
7. Trace the main execution path
8. Review correctness
9. Review edge cases
10. Review failure paths
11. Review concurrency/async when relevant
12. Review state transitions when relevant
13. Review persistence/data integrity when relevant
14. Review API/contracts when relevant
15. Review security when relevant
16. Review performance when relevant
17. Review architecture
18. Review tests
19. Verify important findings
20. Produce the final verdict

Do not mechanically execute every category for every change.
Use judgment and focus on areas relevant to the specific change.

## Implementation in Context

Do not review the diff in isolation.
When necessary, inspect:
* callers,
* callees,
* interfaces,
* implementations,
* related state,
* tests,
* configuration,
* database schema,
* lifecycle owners,
* error handling,
* related modules.

A small diff can have a large behavioral impact.
Diff size is not a proxy for risk.

## Correctness

Look for:
* incorrect conditions,
* wrong assumptions,
* incorrect state transitions,
* stale state,
* incorrect ordering,
* missing branches,
* incorrect defaults,
* incorrect error propagation,
* incorrect return values,
* inconsistent state,
* data corruption,
* lifecycle issues.

## Edge Cases

Actively consider:
* null / missing values,
* empty collections,
* zero,
* negative values,
* maximum values,
* duplicates,
* repeated calls,
* first invocation,
* last invocation,
* already-completed state,
* partially initialized state,
* invalid input,
* unexpected ordering,
* concurrent execution.

Do not report an issue merely because an edge case is theoretically possible.
There must be:
* a realistic path to the problem,
* meaningful impact.

## Failure Paths

For every important operation ask: "What happens if this fails?"
Check:
* network failure,
* timeout,
* cancellation,
* database failure,
* serialization failure,
* invalid response,
* unavailable dependency,
* partial operation,
* retry,
* repeated retry,
* lifecycle/process interruption.

## Concurrency / Async

When the change involves asynchronous or concurrent code, explicitly check:
* race conditions,
* lost updates,
* stale results,
* ordering,
* duplicate execution,
* cancellation,
* coroutine scope/lifecycle,
* shared mutable state,
* synchronization,
* atomicity,
* thread confinement.

Especially consider:
```text
A starts
B starts
B finishes
A finishes
```
Can A overwrite the result produced by B?

## State Machines

For code managing state, check:
* valid states,
* valid transitions,
* invalid transitions,
* terminal states,
* reset behavior,
* repeated transitions,
* concurrent transitions,
* state invariants.

## Persistence / Data Integrity

For database, cache, or storage changes, check:
* atomicity,
* consistency,
* transactions,
* rollback,
* partial writes,
* duplicate records,
* migrations,
* compatibility with old data,
* schema constraints,
* idempotency,
* concurrent writes.

## API / Contracts

Check:
* callers,
* implementations,
* backwards compatibility,
* error contracts,
* nullability,
* serialization,
* defaults,
* versioning,
* platform-specific behavior.

## Security

For security-relevant changes, check:
* authentication,
* authorization,
* input validation,
* trust boundaries,
* sensitive data exposure,
* insecure defaults,
* privilege escalation,
* injection,
* secrets,
* sensitive logging.

A security finding must have a concrete attack or exposure path.

## Performance

Review performance only when the change can realistically affect it.
Look for:
* unnecessary repeated work,
* accidental O(n²) behavior,
* unbounded memory growth,
* blocking operations,
* unnecessary network/database calls,
* repeated serialization,
* expensive work on the wrong thread.

Do not report micro-optimizations without meaningful impact.

## Architecture

Check:
* dependency direction,
* coupling,
* duplicated responsibilities,
* leaked implementation details,
* misplaced business logic,
* inappropriate abstractions,
* module boundaries,
* unnecessary dependencies,
* architecture-specific special cases.

Do not propose a large refactor merely because an alternative design exists.
Only raise architectural issues when the current implementation creates a concrete problem.

## Test Review

Do not evaluate test quality based on test count.
Check whether tests cover:
* main behavior,
* important edge cases,
* failure paths,
* state transitions,
* regression scenarios,
* concurrency where relevant.

Key question: "What bug could still exist even though these tests pass?"
Evaluate test coverage relative to the requirements and risk of the change, not merely the size of the diff.

## Adversarial Review

When the review is performed by `reviewer-adversarial`, adopt the mindset:
"Assume the implementation is wrong. Try to break it."

Construct concrete failure scenarios.
Prioritize:
* race conditions,
* invalid states,
* cancellation,
* retries,
* duplicates,
* stale data,
* partial failures,
* unexpected ordering,
* malformed input,
* lifecycle changes.

Do not merely write: "This might fail under concurrency."
Instead, establish a concrete mechanism such as:
```text
A starts
B starts
B updates state
A finishes with stale data
A overwrites B
```

If a scenario cannot be reasonably justified from the code and context, do not report it as a BLOCKER.

## Evidence Standard

Every finding must be evidence-based.
Before reporting a finding, establish:
1. Where the problem occurs.
2. What execution path triggers it.
3. Why the current implementation behaves incorrectly.
4. What the impact is.

Preferred format:
```text
[file:line] — When X happens, Y can occur because Z.
```

If the problem cannot be confirmed:
```text
[VERIFY]
```

Do not present speculation as fact.

## Severity

### BLOCKER
Use BLOCKER for issues such as:
* core requirement violations,
* broken important functionality,
* data corruption,
* serious security issues,
* serious production failures,
* significant correctness/concurrency issues.

### MINOR
Use MINOR for real but non-blocking issues such as:
* meaningful missing tests,
* limited edge cases,
* maintainability problems,
* non-critical error handling.

### VERIFY
Use VERIFY when an important aspect could not be verified.
Do not use VERIFY as a substitute for investigation that could reasonably have been performed.

## False Positive Control

Before reporting an issue, ask:
1. Is it actually reachable?
2. Does existing code already prevent it?
3. Is this behavior intentional?
4. Does the requirement actually require something different?
5. Is the impact meaningful?
6. Am I reporting a preference instead of a defect?

Prefer fewer high-confidence findings over many speculative findings.

## Duplicate Findings

If multiple problems have the same root cause:
* report the root cause once,
* mention additional affected locations only when necessary.

Do not report the same underlying issue multiple times.

## Verification

When useful and safe, the reviewer may:
* run targeted tests,
* inspect existing test results,
* inspect build/lint output,
* reproduce a suspected issue.

Review remains read-only.
Do not modify:
* source code,
* tests,
* configuration,
* generated files,
* repository state.

## Final Verdict

The reviewer must return exactly one of:
```text
PASS
```
or:
```text
ISSUES:
- [BLOCKER] <file:line> — what is wrong and why
- [MINOR] <file:line> — what is wrong and why
- [VERIFY] <file:line> — what could not be verified
```

No additional prose after the verdict.
Do not add general praise.
Do not report stylistic preferences as defects.