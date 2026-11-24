# Setup Environment Skill

This skill handles OpenClaw environment setup and configuration, including:
- OpenClaw Gateway configuration
- Model provider setup
- Database initialization
- Credential management
- System stability checks

## Responsibilities

- Configure the OpenClaw Gateway
- Set up model providers and authentication
- Initialize state databases
- Manage credentials and tokens
- Ensure system stability
- Run health checks and maintenance

## Usage

Use this skill to:
- Initialize a fresh OpenClaw installation
- Fix configuration issues
- Set up model providers
- Maintain system health

## LiteLLM / Manul model routing

For LiteLLM and FreeLLMAPI setup, follow the maintained
[`freellmapi-environment`](../skills/freellmapi-environment/SKILL.md) and
[`wsl-ai-dev-autopilot-multi-device`](../skills/wsl-ai-dev-autopilot-multi-device/SKILL.md)
skills.

OpenCode and every generated Globalskills OpenCode role use
`litellm/freeLLMAPI` for the main and small model. In the OpenCode
`providers.litellm.models` catalog, the model key is `freeLLMAPI`, while its
upstream `modelID` remains `free-cloud` and matches LiteLLM's single chat
group. Keep the LiteLLM group name `free-cloud`; do not add agent-specific
chat aliases or configure OpenCode Zen (`https://opencode.ai/zen/v1`) as a
LiteLLM upstream. OpenClaw continues to select `litellm/free-cloud`.
Manul does not inject a model override; its OpenCode workers inherit the
operator's configured `model` and `small_model`. Preserve the separate
`multilingual-e5-base` embedding-only LiteLLM alias for Caracal when local
Ollama embeddings are enabled; it is not a chat route.

## Files

This skill provides scripts for:
- Gateway startup and configuration
- Model provider setup
- Database migration and maintenance
- System health monitoring
