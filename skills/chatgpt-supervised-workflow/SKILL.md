---
name: chatgpt-supervised-workflow
description: Enforce an evidence-driven execution workflow for tasks originating from ChatGPT. Use when a task contains a ChatGPT chatId or explicitly identifies ChatGPT as the supervisor. Focus on preserving task context, making small verifiable changes, independently validating results, and never claiming completion without evidence.
license: MIT
---

# ChatGPT Supervised Workflow

## Purpose

Use this skill when Manul or another coding agent receives work originating from a ChatGPT conversation.

The `chatId` is the correlation signal that the task is part of a ChatGPT-supervised workflow. It is not itself a prompt to modify code; it identifies the supervisory context that must be preserved throughout execution.

This skill is deliberately narrow: it governs **how** to execute and verify ChatGPT-originated work. It does not replace the task requirements, repository-specific skills, or normal coding instructions.

## Activation

Activate this skill when either condition is true:

1. The task contains a ChatGPT `chatId`.
2. The task explicitly states that ChatGPT is supervising the work.

Do not activate this workflow solely because a task is complicated. Ordinary tasks without ChatGPT supervision should use the normal workflow.

## Authority and Context

- Treat the explicit task requirements from ChatGPT as authoritative.
- Preserve the `chatId` throughout the workflow and include it in internal task metadata/logging when the surrounding system supports it.
- Do not silently replace an explicit requirement with a different interpretation because it appears simpler.
- Previous agent statements are not evidence. Re-read the repository and verify the current state.
- When a requirement is already established in the task context, do not ask the supervisor to repeat it.
- Do not invent missing requirements. State uncertainty and verify from available repository state, tests, or authoritative task context.

## Core Rule: Evidence, Not Claims

Never report an action as completed merely because the local state suggests that it happened.

Examples:

- A local commit is not proof that the remote branch contains the commit.
- A passing test is not proof that the implementation satisfies an invariant unless the test actually exercises that invariant.
- A previous agent report is not proof that a change exists.
- A clean working tree is not proof that the requested behavior is correct.
- A successful command with weak assertions is not proof of the underlying requirement.

Every material completion claim must have a concrete verification result behind it.

## Execution Workflow

For each material change, follow this sequence:

### 1. Inspect

Establish the actual current state before editing:

- current branch and commit
- relevant files and their current contents
- existing tests covering the requested behavior
- relevant invariants or constraints already established by the supervisor

Do not rely on memory of an earlier iteration when the repository can be inspected directly.

### 2. Define the Smallest Change

Translate the request into a small, explicit change set.

Prefer surgical edits over broad refactors. Do not modify unrelated code just because it is nearby or could be improved.

Before implementing, identify the success criteria that must be demonstrably true after the change.

### 3. Implement

Make only the changes required to satisfy the current request and its established invariants.

Preserve existing behavior outside the requested scope.

### 4. Targeted Verification

Run the smallest relevant test or verification first.

The verification must actually exercise the requested behavior. If it does not, do not use it as evidence that the requirement is satisfied.

For failure-mode, concurrency, idempotency, crash-recovery, or lifecycle requirements, test the relevant failure/race window rather than only the happy path.

### 5. Diff Audit

Inspect the resulting diff and verify:

- every changed line is relevant to the task
- no accidental files or runtime artifacts were added
- established invariants were not weakened
- tests assert the required behavior rather than merely executing code

### 6. Broader Verification

Run the relevant repository test suite when the change can affect adjacent behavior.

When a failure is claimed to be pre-existing, prove it when practical by running the same check against the parent revision or otherwise providing repository evidence.

Never hide a failure behind a weaker command, `|| true`, output filtering, or a reinterpretation of the requirement.

### 7. Commit and Publish

When the task requires a commit or push:

- commit the actual verified changes
- push the intended branch
- verify the published state independently

For Git repositories, when remote verification is required, use both the local remote-tracking ref and the remote advertisement where available:

```bash
git fetch origin
git rev-parse origin/<branch>
git ls-remote origin refs/heads/<branch>
```

The relevant SHAs must match before claiming that the remote contains the changes.

### 8. Final Report

Report facts and evidence, not confidence or assumptions.

A good report states:

- what changed
- what was verified
- exact test commands and outcomes where material
- exact commit SHA when relevant
- exact remote SHA when push was required
- any remaining failures or limitations

Do not report `DONE`, `SUCCESS`, `FIXED`, or equivalent when any required verification step is incomplete or failed.

## Invariant Preservation

ChatGPT may establish explicit invariants during an ongoing conversation. Once established, treat them as part of the task contract until ChatGPT changes them.

Typical examples include:

```text
same input identity -> same idempotency key
same event concurrently -> exactly one side effect
independent events concurrently -> independent side effects
critical persistence failure -> fail closed
crash after external creation -> retry reuses the existing deterministic resource
remote SHA -> matches the pushed commit
```

When modifying code that implements an invariant, test the invariant directly.

## Context Loss Protection

When the task continues over multiple iterations:

1. Re-read the latest task requirements.
2. Re-check the repository state.
3. Preserve previously established invariants unless explicitly superseded.
4. Ignore stale conclusions from earlier agent runs.
5. Prefer current repository evidence over remembered implementation details.

If a new instruction conflicts with an earlier one, surface the conflict explicitly instead of silently choosing one.

## Scope Control

This skill should not turn every task into a heavyweight ceremony.

For trivial changes, the same principles apply with proportionally lighter verification.

Escalate to the full workflow when the change involves multiple files, external side effects, persistence, concurrency, retries, crashes, lifecycle management, branch publication, or an invariant that can be violated without a simple unit test.

## Hard Stop Conditions

Do not claim completion when:

- the required change was not actually made
- a critical test is failing
- the verification does not cover the requested behavior
- a required failure path was not exercised
- the remote branch was not verified after a required push
- the reported SHA does not match the verified remote SHA
- an established invariant is unverified after a material change

When blocked, report the concrete blocker and the evidence available. Do not fabricate success.
