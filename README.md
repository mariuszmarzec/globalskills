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
| `github-selfhosted-runner` | Provision a self-hosted GitHub Actions runner in Docker on any Linux host (WSL2, VM, bare metal). |
| `karpathy-guidelines` | Behavioral guidelines to reduce common LLM coding mistakes. Use when writing, reviewing, or refactoring code to avoid overcomplication, make surgical changes, surface assumptions, and define verifiable success criteria. |
| `kotlin-code-formatting` | Code formatting and style rules for Kotlin. Use when writing, editing, or reviewing Kotlin code in an Android/Gradle project that enforces these rules via detekt (config/detekt/detekt.yml) and Kotlin official style. Run ./gradlew detekt to verify. |
| `quickmvi-usage-testing` | QuickMVI usage and testing guidelines for Kotlin Multiplatform MVI applications. Based on QuickMVI library patterns, testing utilities, and best practices extracted from the QuickMVI project. |
| `litellm-db-setup` | Configure LiteLLM to use a local PostgreSQL database for its UI and auth features. Use when setting up LiteLLM with database support or fixing database connection issues. |
| `manul-github-bot` | Setup, operate, and reinstall the manul GitHub command bot (OpenClaw + gh). Manul reacts to `/manul` in issue/PR comments, implements the task on a `manul/*` branch, pushes, optionally opens a PR, and replies with comments signed "manul 🐈". Use when installing manul on a (new) machine, changing its config, or debugging it. |
| `wsl-ai-dev-autopilot-multi-device` | Fully automated WSL2 AI dev environment (OpenCode compatible). Supports multi-device installation (PC + laptop). Includes hardware-aware model selection, strict healthchecks, self-healing loop, and multi-model LiteLLM routing across 6+ free providers (Groq, Cerebras, Gemini, Mistral, OpenRouter, OpenCode Zen) plus local Ollama. |
| `freellmapi-environment` | Operational notes for running FreeLLMAPI locally and wiring it into LiteLLM (`~/.globalskills/skills/freellmapi-environment/SKILL.md`). |

**Always update this skill list in README.md after adding or removing any skill** to keep documentation synchronized.

## Agents (multi-agent orchestration)

OpenCode agents in `agents/`. Roles define WHAT to do; model tiers define how
much reasoning power. Full routing rules, model mapping, and escalation are in
the `agent-orchestration` skill.

| Agent | Mode | Default tier | Model | Read-only |
|-------|------|--------------|-------|-----------|
| `orchestrator` | primary | EXPERT | `litellm/big-pickle` | no |
| `architect` | subagent | EXPERT | `litellm/big-pickle` | edit: ask |
| `coder-cheap` | subagent | CHEAP | `litellm/groq-llama-8b` | no |
| `coder` | subagent | NORMAL | `litellm/groq-llama-70b` | no |
| `coder-strong` | subagent | STRONG | `litellm/deepseek-v4-flash-free` | no |
| `coder-expert` | subagent | EXPERT | `litellm/big-pickle` | no |
| `reviewer` | subagent | STRONG | `litellm/deepseek-v4-flash-free` | edit: deny |
| `reviewer-expert` | subagent | EXPERT | `litellm/big-pickle` | edit: deny |
| `debugger` | subagent | STRONG | `litellm/deepseek-v4-flash-free` | no |
| `debugger-expert` | subagent | EXPERT | `litellm/big-pickle` | no |
| `researcher` | subagent | CHEAP | `litellm/gemini-3.1-flash-lite` | edit: deny |
| `tester` | subagent | NORMAL | `litellm/groq-llama-70b` | no |
| `security` | subagent | EXPERT | `litellm/big-pickle` | edit: deny |
| `performance` | subagent | STRONG | `litellm/gemini-3.6-flash` | edit: ask |
| `refactorer` | subagent | NORMAL | `litellm/groq-qwen3` | no |

Set `default_agent: "orchestrator"` in `~/.config/opencode/opencode.json` to
route every new session through the orchestrator.

## Manul 🐈

Manul (kot stepowy, Pallas's cat) — the GitHub command bot living in this repo's
skills. Watches configured repositories, reacts to `/manul` in issues/PR
comments, implements tasks on `manul/*` branches, opens PRs, and replies
signed `— manul 🐈`.

```text
        /\_/\
       ( o.o )   manul 🐈 — GitHub command bot
        > ^ <
```

Full setup, baseline semantics, and troubleshooting: `skills/manul-github-bot/SKILL.md`.

## Usage

OpenCode automatically loads skills from `~/.agents/skills/` (symlinked to `~/.globalskills/skills/`). Skills are matched by name and invoked when a task matches their description.
Agents are loaded from `~/.config/opencode/agents/` (symlinked to `~/.globalskills/agents/`).
