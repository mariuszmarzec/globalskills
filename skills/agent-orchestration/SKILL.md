---
name: agent-orchestration

description: Rules for the OpenCode multi-agent orchestration system. Use when running as the orchestrator agent, deciding which role agent to dispatch, which model tier fits a task, when to escalate, or how to produce the routing report. Applies to architect, coder, reviewer, debugger, researcher, tester, security, performance, refactorer roles.
---

# Agent Orchestration

## Core separation

- **Role** = WHAT the agent does (architect, coder, reviewer, ...).
- **Skill** = HOW / with what knowledge the work is done.
- **Model tier** = HOW MUCH reasoning power / how expensive the work is.
- **GitHub CLI** = Any role may use the GitHub CLI (`gh`) for repository operations such as checking out branches, creating commits, pushing changes, creating pull requests, or commenting on PRs.

Model routing is independent of roles. Any role can run on any tier. Change
models here (or in the LiteLLM config) without rebuilding the agents.

## Model tiers (audit of LiteLLM @ localhost:4000, 2026-08-10)

All 19 models in the LiteLLM model_list respond successfully and are **free**
(no paid model is configured — OpenCode Zen is used only for its free models:
`big-pickle`, `deepseek-v4-flash-free`). Tiers are based on measured latency,
context window, cost, and known capability.

| Tier | Default model | Rationale | Alternatives |
|------|---------------|-----------|--------------|
| CHEAP | `litellm/groq-llama-8b` | free, 128k ctx, adequate for trivial single-file edits | `litellm/gemini-3.1-flash-lite` (1M ctx), `litellm/deepseek-v4-flash-free` |
| NORMAL | `litellm/groq-llama-70b` | free, 70B, solid general coding | `litellm/groq-qwen3`, `litellm/cerebras-gpt-oss-120b`, `litellm/gemini-3.5-flash`, `litellm/mistral-large` |
| STRONG | `litellm/deepseek-v4-flash-free` | free, fast, strong reasoning (Zen free tier) | `litellm/gemini-3.6-flash`, `litellm/mistral-codestral`, `litellm/cerebras-gpt-oss-120b` |
| EXPERT | `litellm/big-pickle` | free, strongest reasoning (Zen stealth model) | `litellm/deepseek-v4-flash-free` |

Every model is free. Escalate only when the current tier demonstrably fails.

## Role agents

| Agent | Default tier | Model | Read-only |
|-------|--------------|-------|-----------|
| `architect` | EXPERT | `litellm/big-pickle` | edit: ask |
| `coder-cheap` | CHEAP | `litellm/groq-llama-8b` | no |
| `coder` | NORMAL | `litellm/groq-llama-70b` | no |
| `coder-strong` | STRONG | `litellm/deepseek-v4-flash-free` | no |
| `coder-expert` | EXPERT | `litellm/big-pickle` | no |
| `reviewer` | STRONG | `litellm/deepseek-v4-flash-free` | edit: deny |
| `reviewer-expert` | EXPERT | `litellm/big-pickle` | edit: deny |
| `reviewer-adversarial` | STRONG (or EXPERT for high‑risk) | `litellm/deepseek-v4-flash-free` (or `litellm/big-pickle`) | edit: deny |
| `debugger` | STRONG | `litellm/deepseek-v4-flash-free` | no |
| `debugger-expert` | EXPERT | `litellm/big-pickle` | no |
| `researcher` | CHEAP | `litellm/gemini-3.1-flash-lite` | edit: deny |
| `tester` | NORMAL | `litellm/groq-llama-70b` | no |
| `security` | EXPERT | `litellm/big-pickle` | edit: deny |
| `performance` | STRONG | `litellm/gemini-3.6-flash` | edit: deny |
| `refactorer` | NORMAL | `litellm/groq-qwen3` | no |

## Complexity classification

| Tier | Signals |
|------|---------|
| CHEAP | rename class, add field, fix typo, simple null check, simple endpoint, small obvious bug |
| NORMAL | regular feature, new repository method, endpoint + validation + tests, pagination, standard refactoring |
| STRONG | multi-module change, complex debugging, large refactor, non-trivial concurrency, database redesign, significant integration |
| EXPERT | architecture redesign, complex production bug, race condition, security-critical change, high uncertainty, major architectural decision |

Consider: number of files likely changed, degree of uncertainty, required
reasoning, architectural impact, error risk, concurrency, security, database
changes, cross-module changes, debugging difficulty, need for research.

Do not demand a perfect classification. When unsure, pick the lower tier and
escalate on failure — unless the task is obviously high-risk, then start high.

## Escalation

```
CHEAP → NORMAL → STRONG → EXPERT
```

Escalate only when the current tier genuinely cannot handle the task:

- agent does not understand the problem,
- agent is not confident in the solution,
- tests still fail after a reasonable attempt,
- an architectural problem was discovered,
- scope turned out bigger than expected,
- an unexpected problem appeared,
- review result is negative.

Do NOT escalate after every error. Let the agent fix an obvious mistake first.
Escalate when the problem exceeds the current tier's ability.

Escalation maps to variant agents:
`coder-cheap` → `coder` → `coder-strong` → `coder-expert`,
`reviewer` → `reviewer-expert`, `debugger` → `debugger-expert`.

## Token efficiency

- Never send the whole repository when it is not needed.
- Researcher passes only relevant findings to the next agent.
- Reviewer receives primarily the diff + requirements.
- Debugger receives stack trace + relevant code.
- Architect receives what is needed for the architectural decision.
- Do not forward full transcripts between agents. The Task tool prompt IS the
  context boundary — keep it selective.

## Workflow size classification

Add a new concept to complement complexity and risk:

### MINIMAL

One executor or one small delegation + verification. Use for simple, low-risk tasks.

Examples:
- rename variable
- change string
- update constant
- simple documentation change
- simple configuration change
- straightforward mechanical refactor
- trivial verification task

### STANDARD

A small number of stages such as:
- `architect` → `coder` → `tester` → `reviewer`
- `coder` → `tester` → `reviewer`
- `coder` → `reviewer` (with verification)

### EXTENDED

Multiple specialized agents and/or review loops. Use only when complexity
or risk genuinely requires it.

Examples:
- HIGH RISK feature with expert reviewer + adversarial reviewer
- Concurrency-sensitive change
- Security-critical change
- Large architectural change

Workflow size is NOT determined solely by complexity. A high-risk one-line
change may need EXTENDED review. A large but mechanical low-risk change may
remain STANDARD or MINIMAL.

## Minimum sufficient workflow process

Follow these 11 conceptual steps:

1. **Understand** the requested outcome and user intent.
2. **Classify intent/scope** - answer / explain / simple edit / implement /
   fix / refactor / test / research / delivery.
3. **Classify complexity** - CHEAP / NORMAL / STRONG / EXPERT.
4. **Classify risk** independently - LOW / NORMAL / HIGH / CRITICAL.
   - Risk depends on what the change touches, not line count.
   - Examples: auth change = HIGH, DB migration = HIGH,
     UI label change = LOW, payment logic = HIGH/CRITICAL.
5. **Select minimum sufficient workflow** - MINIMAL / STANDARD / EXTENDED.
   - Based on: what is the minimum workflow that can reliably complete this task?
   - Use complexity AND risk AND intent to determine workflow size.
   - Do NOT default to standard pipeline.
6. **Dispatch only necessary roles** using the selected workflow.
   - Use the minimum number of agents justified by the task.
   - Do NOT add agents merely because they exist.
7. **Evaluate the result** and check for concrete unresolved problems.
8. **Continue only when a concrete unresolved problem exists** - do not
   continue simply because another stage exists.
9. **Fix/review only when necessary** based on actual issues found.
10. **Perform delivery only if requested** - git operations are delivery.
11. **Enter DONE as soon as requested outcome is complete**.

## Conditional stage usage

### Architect
- Use when:
  - architecture is genuinely affected
  - multiple modules/components interact
  - requirements involve significant design choices
  - tradeoffs need explicit analysis
  - implementation is sufficiently complex that planning reduces risk
- Do NOT use for:
  - simple local changes
  - straightforward bug fixes
  - simple configuration changes
  - obvious mechanical refactors

### Coder
- Use for implementation tasks that are not trivial.
- For trivial changes, consider `coder-cheap` or direct execution.

### Tester
- Use when:
  - the task changes behavior that meaningfully requires testing
- Do NOT use for:
  - documentation-only changes
  - comments
  - simple renames
  - trivial formatting
  - purely mechanical changes
  - changes where targeted verification is sufficient
- High-risk changes require appropriate verification even if diff is small.

### Reviewer
- Use when:
  - review is justified by risk/behavior
  - requirements compliance needs checking
  - correctness, edge cases, error handling verification needed
- Do NOT use automatically for every task.

### Reviewer-expert
- Use for:
  - high-risk changes (security, auth, concurrency, data integrity)
  - direct reviewer (not only escalation) for high-risk tasks
- Do NOT use for low-risk changes.

### Reviewer-adversarial
- Use for:
  - correctness/concurrency/state behavior dominant concern
  - adversarial perspective to try to break implementation
- Do NOT use for routine UI changes or low-risk tasks.

### Researcher
- Use only when:
  - research is genuinely needed for understanding the problem
  - external context required for implementation
- Do NOT use for simple implementation tasks.

### Debugger
- Use for:
  - debugging problems
- Use `debugger-expert` only when:
  - complex debugging requires expert analysis

### Security
- Use for:
  - security-relevant changes
  - security review of implementation
- Use `security-expert` when available for enhanced analysis.

### Performance
- Use for:
  - performance concerns
  - optimization opportunities

### Refactorer
- Use for:
  - significant refactoring that requires specialized refactorer skills

## Risk-based reviewer selection

**LOW RISK:**
- `coder` → `reviewer` (or `coder` → `reviewer` with verification)

**NORMAL FEATURE:**
- `architect` → `coder` → `tester` → `reviewer`

**HIGH RISK:**
- `architect` → `coder` → `tester` → `reviewer-expert`;
  add `reviewer-adversarial` if correctness/concurrency/state behavior
  is dominant.

**SECURITY:**
- `coder` → `tester` → `reviewer-expert`

**CONCURRENCY:**
- `coder` → `tester` → `reviewer-expert` + `reviewer-adversarial`

**DB / DATA INTEGRITY:**
- `coder` → `tester` → `reviewer-expert`

## Stop rule

After every stage, ask internally:

"Is there a concrete unresolved problem that requires another agent or
another iteration?"

If NO: STOP and proceed to DONE if the requested outcome is complete.

If YES: Dispatch only the role required to resolve that specific problem.
Do not restart the entire pipeline unless the unresolved problem genuinely
requires it.

Examples:
- Reviewer returns PASS → DONE (do NOT call another reviewer "for extra confidence")
- Tests pass and implementation is complete → DONE (do NOT perform another
  implementation pass)

## Delivery as terminal phase

Treat operations as DELIVERY:

* git status
* git diff
* git add
* git commit
* git push
* branch creation
* pull request creation
* pull request updates

DELIVERY is a terminal workflow phase, not implementation work.

If user requests:
"Implement X, commit, push, and create a PR"

Workflow should be:
1. IMPLEMENT
2. VERIFY
3. REVIEW if justified
4. DELIVER (commit, push, create PR)
5. DONE

Do NOT restart coding/review because a delivery operation was requested.

Once implementation has passed required verification/review, delivery should be final.

## Delivery failure vs implementation failure

**Implementation failure:**
- code is incorrect
- tests fail
- requirements not satisfied
- reviewer finds real issue

→ return to appropriate implementation/review stage.

**Delivery failure:**
- git commit fails
- push fails
- PR creation fails
- branch operation fails

→ resolve the delivery problem only.

DO NOT automatically restart the implementation pipeline because of delivery failure.

## DONE as terminal state

Introduce explicit DONE state:

```
DONE
```

Once:
- requested work is complete
- required verification has succeeded
- required review has passed
- requested delivery operations have succeeded

Workflow enters DONE.

After entering DONE:
- do not call additional agents
- do not perform additional reviews
- do not re-run implementation pipeline
- do not proactively improve code
- do not perform unrelated cleanup

Return final report.

A successful delivery operation must terminate the workflow.

## Proportionality check

Before dispatching an additional agent, perform internal check:

```
What concrete value will this agent add?
What unresolved risk/problem does it address?
Is that value worth the additional complexity and cost?
Is this the minimum role that can address the problem?
```

If expected value is low and no meaningful unresolved issue:
STOP.

## Do not confuse completeness with quality

More agents do not automatically produce a better result.

Avoid:
```
more agents = better
```

Prefer:
```
appropriate agents = better
```

Optimize for:
- correctness
- requirement compliance
- appropriate verification
- risk coverage
- efficiency
- minimal unnecessary work

## Escalation justification

Every escalation requires concrete reason:

Before escalating, determine:
1. What unresolved problem exists?
2. Why can the current agent/result not resolve it?
3. Why is the stronger role the minimum adequate role?

If no concrete answers:
Do NOT escalate.

Do NOT escalate simply because:
- stronger model is available
- task feels important
- another reviewer exists
- additional confidence would be nice

Escalation is for unresolved problems, not for completeness theater.

## Fix → test → review rule

Preserve existing rule:

When a review finds real issues:
```
coder fix → re-run applicable verification → re-run relevant original reviewers
```

Do not expand review set unless fix introduces new risk.

Keep maximum 2 review rounds.
Do not create endless review loop.

## Dispatch contract

Every Task tool call must request structured summary including:
- what was changed (files)
- verification performed (tests/lint commands + result)
- any remaining uncertainty or blockers
- confidence (high/medium/low)

Do not weaken this contract.

## Report format

At the end of every task the orchestrator must report:

```text
Task: <description>
 
Role:
 <agent(s) used>
 
Initial tier:
 <CHEAP | NORMAL | STRONG | EXPERT>
 
Model:
 <actual model per agent>
 
Reason:
 <why this tier/role>
 
Escalated:
 <NO | YES - from X to Y>
 
Steps:
 <n>
 
Result:
 <SUCCESS | FAILURE | ESCALATED>
 ```
