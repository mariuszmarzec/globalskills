# Setup Environment (legacy entrypoint)

This directory retains the original OpenClaw setup scripts and requirements.
For maintained environment setup and repair instructions, use:

- [WSL AI Dev Autopilot](../skills/wsl-ai-dev-autopilot-multi-device/SKILL.md)
- [FreeLLMAPI Environment](../skills/freellmapi-environment/SKILL.md)

## LiteLLM, OpenCode and Manul routing

Keep exactly one LiteLLM chat model group named `free-cloud`, backed by
FreeLLMAPI `openai/auto`. The client-side model selector is not necessarily
the LiteLLM group name:

- **OpenCode:** use provider key `litellm`, model-catalog key `freeLLMAPI`,
  and selector `litellm/freeLLMAPI`. The OpenCode model entry must send
  upstream `modelID: "free-cloud"`.
- **OpenClaw:** use provider model ID `free-cloud`, selected as
  `litellm/free-cloud`.
- **Manul:** do not add a Manul model setting and do not pass `--model` to
  OpenCode. Manul leaves model/provider selection to the selected runtime and,
  for OpenCode tasks, uses the operator's OpenCode configuration.

Generated Globalskills OpenCode role definitions must use the selector that
matches the configured OpenCode provider catalog key. For the configuration
above, that selector is `litellm/freeLLMAPI`. Do not confuse it with the
LiteLLM upstream group name `free-cloud`, or create per-role LiteLLM chat
aliases.

Preserve the separate `multilingual-e5-base` embedding-only LiteLLM alias for
Caracal when local Ollama embeddings are enabled. It is not a chat route.

## Files

This legacy directory provides scripts for:
- Gateway startup and configuration
- Model provider setup
- Database migration and maintenance
- System health monitoring
