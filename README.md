# Global Skills Repository

Shared skills for OpenCode AI agents. Each skill lives in its own folder with a `SKILL.md` definition file.

## Quick Install

```bash
wget -qO /tmp/install-globalskills.sh https://raw.githubusercontent.com/mariuszmarzec/globalskills/master/install.sh && bash /tmp/install-globalskills.sh
```

This clones the repo to `~/.globalskills` and symlinks `~/.agents/skills -> ~/.globalskills/skills`.

## Updating

```bash
git -C ~/.globalskills pull
```

## Skills

| Skill | Description |
|-------|-------------|
| `github-selfhosted-runner` | Provision a self-hosted GitHub Actions runner in Docker on any Linux host (WSL2, VM, bare metal). |
| `karpathy-guidelines` | Behavioral guidelines to reduce common LLM coding mistakes. Use when writing, reviewing, or refactoring code to avoid overcomplication, make surgical changes, surface assumptions, and define verifiable success criteria. |
| `kotlin-code-formatting` | Code formatting and style rules for Kotlin. Use when writing, editing, or reviewing Kotlin code in an Android/Gradle project that enforces these rules via detekt (config/detekt/detekt.yml) and Kotlin official style. Run ./gradlew detekt to verify. |
| `litellm-db-setup` | Configure LiteLLM to use a local PostgreSQL database for its UI and auth features. Use when setting up LiteLLM with database support or fixing database connection issues. |
| `wsl-ai-dev-autopilot-multi-device` | Fully automated WSL2 AI dev environment (OpenCode compatible). Supports multi-device installation (PC + laptop). Includes hardware-aware model selection, strict healthchecks, self-healing loop, and multi-model LiteLLM routing across 6+ free providers (Groq, Cerebras, Gemini, Mistral, OpenRouter, OpenCode Zen) plus local Ollama. |

## Usage

OpenCode automatically loads skills from `~/.agents/skills/` (symlinked to `~/.globalskills/skills/`). Skills are matched by name and invoked when a task matches their description.
