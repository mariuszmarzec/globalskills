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

Manul and every generated Globalskills role must use the OpenCode model
selector `litellm/free-cloud`, backed by the single FreeLLMAPI chat group.
Do not configure OpenCode Zen (`https://opencode.ai/zen/v1`) as a LiteLLM
upstream or introduce agent-specific chat aliases. Preserve the separate
`multilingual-e5-base` embedding-only LiteLLM alias for Caracal when local
Ollama embeddings are enabled; it is not a chat route. The OpenCode provider
key and model key are `litellm` and `free-cloud` respectively, and the
upstream `modelID` is also `free-cloud`.

## Files

This skill provides scripts for:
- Gateway startup and configuration
- Model provider setup
- Database migration and maintenance
- System health monitoring
