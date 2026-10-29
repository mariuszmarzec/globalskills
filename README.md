# Global Skills Repository

Shared skills and OpenCode agents for the multi-agent orchestration system.
Each skill lives in its own folder with a `SKILL.md` definition file; each
agent lives in `agents/<name>.md`.

## Quick Install

```bash
wget -qO /tmp/install-globalskills.sh https://raw.githubusercontent.com/mariuszmarzec/globalskills/master/install.sh && bash /tmp/install-globalskills.sh
```

This clones the repo to `~/.globalskills` and symlinks:

- `~/.agents/skills -> ~/.globalskills/skills`
- `~/.config/opencode/agents -> ~/.globalskills/agents`
- `~/.aicode/aicode -> ~/.globalskills/aicode/aicode` (the installer backs up an existing launcher instead of overwriting it)

Skills are loaded by OpenCode via `skills.paths` in `~/.config/opencode/opencode.json`.
Agents are discovered from `~/.config/opencode/agents/` (the symlink above).

## Updating

```bash
git -C ~/.globalskills pull
```

## Skills

| Skill | Description |
|-------|-------------|
| `agent-orchestration` | Rules for the OpenCode multi-agent orchestration system. Use when running as the orchestrator agent, deciding which role agent to dispatch, which model tier fits a task, when to escalate, or how to produce the routing report. |
| `ai-commit-attribution` | Preserve the human developer as the Git commit author and add a Co-authored-by trailer to every AI-created commit. Use whenever creating a Git commit. Never change Git author config, never use --author, and always append the OpenCode <opencode@ai.local> trailer (or the identity of the active agent outside OpenCode). |
| `feature-branching-strategy` | Branching strategy for changes made by an AI agent. Use whenever pushing code changes to a repository (except the ~/.globalskills repo) — always create a feature/<ISSUE_NUMBER-if-exists>-<DESCRIPTION> branch, or bugfix/<DESCRIPTION> for bug fixes, and never push directly to the main branch. |
| `pr-description-management` | Manage GitHub Pull Request descriptions - create PRs with proper descriptions and update descriptions when pushing changes. Uses gh CLI for all PR operations. Follows feature-branching-strategy for branch naming. |
| `github-selfhosted-runner` | Provision a self-hosted GitHub Actions runner in Docker on any Linux host (WSL2, VM, bare metal). |
| `karpathy-guidelines` | Behavioral guidelines to reduce common LLM coding mistakes. Use when writing, reviewing, or refactoring code to avoid overcomplication, make surgical changes, surface assumptions, and define verifiable success criteria. |
| `quickmvi-usage-testing` | QuickMVI usage and testing guidelines for Kotlin Multiplatform MVI applications. Consults Caracal RAG's indexed QuickMVI README for documented usage; verify exact behavior against source and tests. |
| `litellm-db-setup` | Configure LiteLLM to use a local PostgreSQL database for its UI and auth features. Use when setting up LiteLLM database support or fixing LiteLLM database connection issues. |
| `unit-testing-language-agnostic` | Universal unit-testing principles, including whole-value assertions when equality is meaningful |
| `manul-github-bot` | Set up, operate, and debug Manul, the GitHub task orchestrator. Automatic tasks use the configured runtime (OpenClaw by default); explicitly selected canonical roles use the configured role runtime (OpenCode by default). Manul owns task state, workspace isolation, retries, result verification, and GitHub delivery. |
| `chatgpt-supervised-workflow` | Enforce an evidence-driven execution workflow for tasks originating from ChatGPT. Use when a task contains a ChatGPT chatId or explicitly identifies ChatGPT as the supervisor. Focus on preserving task context, making small verifiable changes, independently validating results, and never claiming completion without evidence. |
| `wsl-ai-dev-autopilot-multi-device` | Fully automated WSL2 AI dev environment (OpenCode compatible), including isolated Caracal RAG installation, authenticated MCP startup after LiteLLM, hardware-aware model selection, healthchecks, and multi-model LiteLLM routing. |
| `freellmapi-environment` | Operational notes for running FreeLLMAPI locally and wiring it into LiteLLM (`~/.globalskills/skills/freellmapi-environment/SKILL.md`). |
| `fiteo-access` | Connect to the Fiteo backend using the current `FITEO_BASE_URL`, `FITEO_MANUL_USERNAME`, and `FITEO_MANUL_PASSWORD` environment variables. Never hardcode or print their values. |
| `fiteo-backend-api` | Use for Fiteo backend endpoint/API contract questions and related implementation or review work. Search Caracal RAG's `fiteo-docs` source first; verify current code/tests before claiming implementation behavior. |

## Agents (multi-agent orchestration)

OpenCode agents in `agents/`. Roles define WHAT to do; model tiers define how much reasoning power. Full routing rules, model mapping, and escalation are in the `agent-orchestration` skill.

| Agent | Mode | Default tier | Model | Read-only |
|-------|------|-------------|-------|-----------|
| `orchestrator` | primary | EXPERT | `litellm/free-cloud` | no |
| `architect` | all | EXPERT | `litellm/free-cloud` | edit: ask |
| `coder-cheap` | all | CHEAP | `litellm/free-cloud` | no |
| `coder` | all | NORMAL | `litellm/free-cloud` | no |
| `coder-strong` | all | STRONG | `litellm/free-cloud` | no |
| `coder-expert` | all | EXPERT | `litellm/free-cloud` | no |
| `reviewer` | all | STRONG | `litellm/free-cloud` | edit: deny |
| `reviewer-expert` | all | EXPERT | `litellm/free-cloud` | edit: deny |
| `debugger` | all | STRONG | `litellm/free-cloud` | no |
| `debugger-expert` | all | EXPERT | `litellm/free-cloud` | no |
| `researcher` | all | CHEAP | `litellm/free-cloud` | edit: deny |
| `tester` | all | NORMAL | `litellm/free-cloud` | no |
| `security` | all | EXPERT | `litellm/free-cloud` | edit: deny |
| `performance` | all | STRONG | `litellm/free-cloud` | edit: ask |
| `refactorer` | all | NORMAL | `litellm/free-cloud` | no |

Set `default_agent: "orchestrator"` in `~/.config/opencode/opencode.json` to
route every new session through the orchestrator.

## Manul 🐈

Manul (kot stepowy, Pallas's cat) — the GitHub command bot living in this repo's
skills. Watches configured repositories, reacts to `/manul` in issue/PR
comments, implements tasks on `manul/*` branches, opens PRs, and replies
signed `— manul 🐈`.

```text
        /\_/\\
       ( o.o )
        > ^ <
```

Full setup, runtime/role routing, session continuation, baseline semantics, and troubleshooting: `skills/manul-github-bot/SKILL.md`.

## Skill Benchmarks

Behavioral benchmarks for skills live in `skill-benchmarks/`. They run the real
agent locally against a fresh fixture and use deterministic verifiers to check
the resulting behavior. OpenCode is the current backend behind an adapter so
the benchmark runner can be switched later without changing benchmark cases.

Run a case:

```bash
python3 skill-benchmarks/benchmark.py run --case commit-trailer
```

Compare with and without the skill:

```bash
python3 skill-benchmarks/benchmark.py run --case commit-trailer --mode both
```

Run all non-excluded benchmarks in one diagnostic run:

```bash
python3 skill-benchmarks/benchmark.py run-all --mode both
```

This produces one aggregate report under `skill-benchmarks/output/<run-id>/`
with per-case failures and skill impact signals.

Each live run writes a self-contained report under `skill-benchmarks/output/<run-id>/`, including the with/without-skill comparison, tested `SKILL.md` snapshot, agent output, verifier result, and git artifacts. The output directory is ignored by git.

The benchmark suite is deliberately not wired into CI. Its framework and
adapters have local unit tests with mocks, so those tests do not require an
LLM. New skills should add a benchmark unless the skill is explicitly excluded
in `skill-benchmarks/config.json`.

See `skill-benchmarks/README.md` for the case format and conventions.
