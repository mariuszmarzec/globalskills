# Global Skills Repository

Shared skills for OpenCode AI agents. Each skill lives in its own folder with a `SKILL.md` definition file.

## Skills

| Skill | Description |
|-------|-------------|
| `globalskills-repository` | Manage this repository — rules for creating, organizing, and updating skills in `~/.globalskills/skills`. |
| `litellm-db-setup` | Configure LiteLLM to use a local PostgreSQL database for its UI and auth features. Use when setting up LiteLLM with database support or fixing database connection issues. |
| `wsl-ai-dev-autopilot-multi-device` | Fully automated WSL2 AI dev environment (OpenCode compatible). Supports multi-device installation (PC + laptop). Includes hardware-aware model selection, strict healthchecks, self-healing loop, and multi-model LiteLLM routing across 6+ free providers (Groq, Cerebras, Gemini, Mistral, OpenRouter, OpenCode Zen) plus local Ollama. |

## Usage

OpenCode automatically loads skills from `~/.globalskills/skills/`. Skills are matched by name and invoked when a task matches their description.
