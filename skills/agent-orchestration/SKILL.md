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

## Minimal agent set

Use the smallest number of agents that can complete the task well:

- trivial: `coder-cheap` → DONE
- normal feature: `architect` → `coder` → `reviewer` → DONE
- hard feature: `architect` → `coder` → `tester` → `reviewer` → `coder` → DONE
- hard bug: `debugger` → `coder` → `tester` → `reviewer` → DONE
- research needed: `researcher` → `architect` → `coder` → `reviewer` → DONE
- LOW RISK trivial: `coder-cheap` → `reviewer` → DONE
- LOW RISK normal feature: `architect` → `coder` → `reviewer` → DONE
- NORMAL FEATURE: `architect` → `coder` → `tester` → `reviewer` → DONE
- HIGH RISK (security, auth, concurrency, data integrity, significant architecture):
  `architect` → `coder` → `tester` → `reviewer` + `reviewer-expert` [+ `reviewer-adversarial` if correctness/concurrency/state behavior is critical]
- SECURITY‑focused change: `coder` → `tester` → `reviewer-expert` → DONE
- CONCURRENCY / RACE CONDITIONS: `coder` → `tester` → `reviewer-expert` + `reviewer-adversarial` → DONE
- DB / DATA INTEGRITY: `coder` → `tester` → `reviewer-expert` → DONE
- Large refactor: `architect` → `coder` → `tester` → `reviewer-expert` (+ architecture scrutiny by architect/reviewer-expert) → DONE

Never dispatch all agents for every task. Choose the MINIMUM set that gives adequate quality. Do not automatically run all reviewers.

## Reviewer independence

Reviewer is a separate role from Coder, preferably a different model. It is
read-only and returns `PASS` or a list of `ISSUES`. On issues: `coder` →
`tester` → `reviewer` again (including any `reviewer-expert` /
`reviewer-adversarial` that were part of the original review set). Maximum 2
review rounds per implementation attempt.

When multiple independent reviewers are used simultaneously, the orchestrator
aggregates findings: deduplicates, distinguishes blockers from minors, rejects
obvious false positives, and passes only actionable issues to the coder. Do
not forward every reported item without evaluation.

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
