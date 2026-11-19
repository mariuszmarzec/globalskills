---
name: freellmapi-environment
description: Set up the single FreeLLMAPI-backed LiteLLM model group free-cloud. Use when installing, configuring, or troubleshooting the local FreeLLMAPI-to-LiteLLM chat route.
---

# FreeLLMAPI + LiteLLM (single-model setup)

## Goal

Expose exactly one chat model to local clients:

`OpenCode / OpenClaw / Manul → LiteLLM :4000 → FreeLLMAPI :3001/v1 → openai/auto`

LiteLLM must publish only the model group `free-cloud`. Do not add aliases, direct provider entries, local models, or fallback chains. FreeLLMAPI may manage its upstream provider pool internally; LiteLLM clients still see only `free-cloud`.

## Prerequisites

- FreeLLMAPI is running locally and bound to loopback at `127.0.0.1:3001`.
- The FreeLLMAPI dashboard has its upstream provider pool configured.
- A unified FreeLLMAPI API key is available.
- LiteLLM is installed and uses port `4000`.

## Secrets

Store only these two values in `~/litellm/.env`:

```bash
LITELLM_MASTER_KEY=<generate-a-long-random-key>
FREELLMAPI_API_KEY=<your-FreeLLMAPI-unified-key>
```

Protect the file with `chmod 600 ~/litellm/.env`. Never commit keys, paste them into repository files, or print them in logs.

## LiteLLM configuration

Use this as the complete `~/litellm/config.yaml` model configuration:

```yaml
model_list:
  - model_name: free-cloud
    litellm_params:
      model: openai/auto
      api_base: http://127.0.0.1:3001/v1
      api_key: os.environ/FREELLMAPI_API_KEY

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

Do not add `router_settings.fallbacks`, `completion_model`, aliases, or additional `model_list` entries. If PostgreSQL is not part of the local LiteLLM deployment, omit `database_url` rather than creating an unrelated dependency.

## Start and verify

Load the environment in the same process that starts LiteLLM:

```bash
set -a
source ~/litellm/.env
set +a
litellm --config ~/litellm/config.yaml --host 127.0.0.1 --port 4000
```

For a managed service, update its configuration and reload that service instead of starting a second process.

Verify upstream and proxy:

```bash
curl -fsS http://127.0.0.1:3001/v1/models \
  -H "Authorization: Bearer $FREELLMAPI_API_KEY"

curl -fsS http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

The LiteLLM response must contain exactly one model ID: `free-cloud`. Then send a chat completion with `model: free-cloud` and verify a response.

## Routing rules

- OpenCode's main model and small model: `litellm/free-cloud`.
- OpenClaw's default model: `litellm/free-cloud`.
- All Globalskills agent roles and Manul workers: `litellm/free-cloud`.
- Do not use aliases such as `big-pickle` or `deepseek-v4-flash-free`.
- Do not configure Groq, Cerebras, Gemini, Mistral, OpenRouter, Ollama, or OpenCode Zen as LiteLLM model routes.
- LiteLLM retries must retry the same `free-cloud` model group; they must not switch to another provider or model group.

## Troubleshooting

- If FreeLLMAPI `/v1/models` fails, check the process, loopback binding, unified API key, and upstream provider pool.
- If LiteLLM `/v1/models` does not show exactly `free-cloud`, check the active config path and the environment inherited by the LiteLLM process.
- If LiteLLM reports "no healthy deployments", test FreeLLMAPI directly and inspect both services' logs. Do not work around the error by adding aliases or fallback models.
- If tool calls fail, verify the FreeLLMAPI auto pool selects models that support tool calling.

## Embeddings

Caracal RAG embeddings are configured separately in `~/.caracal/config/sources.yaml`. Do not add an embedding model to LiteLLM's chat `model_list`.
