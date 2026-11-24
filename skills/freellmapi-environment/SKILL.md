---
name: freellmapi-environment
description: Configure the single FreeLLMAPI-backed LiteLLM chat group free-cloud and the separate local Ollama embedding alias used by Caracal RAG.
---

# FreeLLMAPI + LiteLLM (single chat route)

## Goal

Keep one chat-completion route for local clients:

`OpenCode / OpenClaw / Manul → LiteLLM :4000 → FreeLLMAPI :3001/v1 → openai/auto`

The only LiteLLM chat model group is `free-cloud`. Do not add chat aliases,
per-role model groups, direct chat providers, or fallback chains. FreeLLMAPI may
manage its upstream provider pool internally; clients select the one chat route
as `litellm/free-cloud`.

Caracal also uses a separate, embedding-only LiteLLM alias backed by local
Ollama. That alias is not a second chat model, is not a fallback, and must never
be selected for chat completions:

`Caracal embeddings → LiteLLM :4000 → Ollama :11434 → multilingual-e5-base`

## Prerequisites

- FreeLLMAPI is running locally and bound to loopback at `127.0.0.1:3001`.
- The FreeLLMAPI dashboard has its upstream provider pool configured.
- A unified FreeLLMAPI API key is available.
- LiteLLM is installed and uses port `4000`.
- Ollama is running locally on port `11434` and has
  `qllama/multilingual-e5-base` available when the Caracal embedding alias is
  enabled.

## Secrets and process environment

LiteLLM needs these values in the environment of the LiteLLM process:

```bash
LITELLM_MASTER_KEY=<generate-a-long-random-key>
FREELLMAPI_API_KEY=<your-FreeLLMAPI-unified-key>
```

Keep credentials out of repository files, command-line arguments and logs.
The LiteLLM service may use its existing private service environment file to
receive these two process credentials. Do not put PATH, tool locations,
OpenCode model selection or general shell configuration in that service file.

For shell-wide settings consumed by interactive clients and unattended Manul
workers, use the operator's existing `~/.zshrc` as the single source of truth.
Do not duplicate PATH/provider settings in `~/.zshenv`, `~/.manul/.env` or
multiple shell startup files. The Manul installer installs its Zsh integration;
direct and unattended Manul entrypoints load the same `~/.zshrc` through
`manul-zsh-bootstrap.sh` (`zsh -ic`) before running their Bash scripts.
Manul's `~/.manul/.env` is reserved for Manul-specific integration fallbacks,
not PATH, provider configuration, provider API keys or OpenCode configuration.

## LiteLLM configuration

Use the following model entries in `~/litellm/config.yaml`. The first is the
only chat-completion route. The second is strictly for embeddings:

```yaml
model_list:
  # The only chat-completion model group.
  - model_name: free-cloud
    litellm_params:
      model: openai/auto
      api_base: http://127.0.0.1:3001/v1
      api_key: os.environ/FREELLMAPI_API_KEY

  # Separate local embedding endpoint for Caracal RAG; never use for chat.
  - model_name: multilingual-e5-base
    litellm_params:
      model: ollama/qllama/multilingual-e5-base
      api_base: http://localhost:11434
      api_key: ollama-local

litellm_settings:
  drop_params: true
  request_timeout: 600
  num_retries: 2
  set_verbose: true
  cache: true
  cache_params:
    type: disk
    disk_cache_dir: /tmp/litellm-cache
    ttl: 3600

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: "postgresql://litellm:litellm@127.0.0.1:5432/litellm"
```

The embedding alias is optional on hosts that do not run Caracal/Ollama. If
Caracal uses this route, preserve the alias and ensure Ollama has the exact model
available. Do not replace it with a FreeLLMAPI chat model or add it to OpenCode's
chat model selector. If PostgreSQL is not part of the local LiteLLM deployment,
omit `database_url` rather than creating an unrelated dependency.

Do not add `router_settings.fallbacks`, `completion_model`, per-role chat
aliases, or additional chat model groups. The two entries above serve different
API purposes; `multilingual-e5-base` is not a chat alias.

## Start and verify

Start or reload the existing LiteLLM service using its normal service manager;
do not start a second proxy process. The service must inherit
`LITELLM_MASTER_KEY` and `FREELLMAPI_API_KEY`.

Verify the upstream and proxy:

```bash
curl -fsS http://127.0.0.1:3001/v1/models \
  -H "Authorization: Bearer $FREELLMAPI_API_KEY"

curl -fsS http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

Verify a chat completion explicitly with `model: free-cloud`. When the
embedding alias is enabled, verify that `multilingual-e5-base` is present in
the active LiteLLM configuration and send an embedding request through that
alias. A working chat route does not prove the local embedding route works;
check Ollama and the embedding endpoint independently.

## Routing rules

- OpenCode's main model and small model: `litellm/free-cloud`.
- OpenClaw's default model: `litellm/free-cloud`.
- All Globalskills agent roles and Manul workers: `litellm/free-cloud`.
- OpenCode's selectable model ID must be constructed from provider key
  `litellm` and model key `free-cloud`: `litellm/free-cloud`.
- The corresponding OpenCode model entry uses upstream `modelID: "free-cloud"`.
  The OpenCode model key is the selectable ID; `modelID` is sent upstream.
- Caracal embeddings may use the separate LiteLLM alias
  `multilingual-e5-base`; it is not a chat model.
- Do not use chat aliases such as `big-pickle` or
  `deepseek-v4-flash-free`.
- Do not configure Groq, Cerebras, Gemini, Mistral, OpenRouter or OpenCode Zen
  as additional LiteLLM chat routes. Ollama is used only for the dedicated
  local embedding alias described above.
- LiteLLM retries must retry the same `free-cloud` chat model group; they must
  not switch to another provider or model group.

## Troubleshooting

- If FreeLLMAPI `/v1/models` fails, check the process, loopback binding,
  unified API key and upstream provider pool.
- If LiteLLM chat completions report "no healthy deployments", test FreeLLMAPI
  directly and inspect both services' logs. Do not work around the error by
  adding aliases or fallback models.
- If `free-cloud` is absent from the active LiteLLM configuration, check the
  config path and the environment inherited by the LiteLLM process.
- If Caracal embeddings fail, check that Ollama is running, the exact
  `qllama/multilingual-e5-base` model is installed, and the
  `multilingual-e5-base` embedding alias points to `http://localhost:11434`.
  Do not change the chat route to fix an embedding failure.
- If tool calls fail, verify that the FreeLLMAPI auto pool selects models that
  support tool calling.

## Manul and OpenCode process isolation

Manul leaves the operator's OpenCode model/provider selection untouched. It
does not inject a model, provider or fallback into the task configuration.
Its OpenCode adapter uses `opencode run --standalone`, and standalone mode for
agent discovery and Caracal MCP preflight, so task processes do not reuse an
already-running OpenCode server with stale environment variables.

Keep the operator's `OPENCODE_API_KEY` and any configured OpenCode Console
provider authentication intact. `OPENCODE_API_KEY` does not select OpenCode
Go. Diagnose the explicitly selected model/provider and the effective
OpenCode config; do not remove unrelated provider authentication as a
workaround for an OpenCode Go subscription error.
