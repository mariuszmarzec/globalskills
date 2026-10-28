---
name: wsl-ai-dev-autopilot-multi-device
description: Fully automated WSL2 AI dev environment (OpenCode + OpenClaw compatible). Supports multi-device installation (PC + laptop), hardware-aware model selection, strict healthchecks, self-healing, multi-model LiteLLM routing, local Ollama, and Caracal RAG MCP integration. Use when setting up or repairing a WSL2 AI dev environment with Ollama, LiteLLM, OpenCode, OpenClaw, and Caracal RAG.
---

# WSL AI Dev Autopilot Skill

# Purpose

This skill guides an AI agent through the complete installation and validation of an AI development environment on WSL2. It configures LiteLLM as a proxy exposing 20+ models to OpenCode and OpenClaw, installs Caracal RAG into its isolated runtime under ~/.caracal, and configures the authenticated loopback HTTP MCP endpoint for OpenCode. In this deployment, OpenClaw invokes OpenCode through ACPX, so the aicode launcher configures the ACPX opencode harness to use a wrapper that refreshes Caracal credentials and checks the live MCP connection before starting opencode acp. Caracal's embeddings endpoint and vector database remain separately configured dependencies; do not assume the LiteLLM chat model list provides an embedding model.

## Architecture

```text
OpenCode Client        OpenClaw Gateway (Port 18789)
        │                       │
        └───────────┬───────────┘
                    ▼
LiteLLM (Router & Proxy - Port 4000)
        │
        ├── Free Cloud Models (via API keys)
        │   ├── Groq (fastest, ~320 tok/s)
        │   │   ├── groq-llama-70b (Llama 3.3 70B)
        │   │   ├── groq-qwen3 (Qwen3.6 27B)
        │   │   └── groq-llama-8b (Llama 3.1 8B)
        │   ├── Cerebras (~2600 tok/s)
        │   │   ├── cerebras-gpt-oss-120b
        │   │   ├── cerebras-gemma-31b (Gemma 4 31B)
        │   │   └── cerebras-glm-4.7 (GLM 4.7)
        │   ├── Google Gemini (free tier)
        │   │   ├── gemini-3.6-flash (3.6 Flash, 20 RPD)
        │   │   ├── gemini-3.5-flash (3.5 Flash, 20 RPD)
        │   │   ├── gemini-3.5-flash-lite (500 RPD)
        │   │   ├── gemini-3.1-flash-lite (500 RPD)
        │   │   ├── gemma-4-31b (Gemma 4 31B, 14.4K RPD)
        │   │   └── gemma-4-26b (Gemma 4 26B, 14.4K RPD)
        │   ├── Mistral (1B tokens/month)
        │   │   ├── mistral-large (Mistral Large)
        │   │   └── mistral-codestral (Codestral, code-specialized)
        │   ├── OpenRouter (Free Models Router)
        │   │   └── or-free (auto-routes to live :free models)
        │   └── OpenCode Zen (Cloud)
        │       ├── big-pickle (Free)
        │       └── deepseek-v4-flash-free (Free)
        │
        └── Local Ollama Models
            ├── gemma4 (gemma4:12b)
            └── local-coder (Fallback)
```

The local RAG path is: OpenCode -> authenticated Caracal MCP on 127.0.0.1 -> configured Chroma collection. Caracal computes document and query embeddings through LiteLLM's OpenAI-compatible endpoint at `http://127.0.0.1:4000/v1`. LiteLLM exposes the alias `multilingual-e5-base`, routed to Ollama model `qllama/multilingual-e5-base`. The E5 prefix behavior is implemented in [caracal-rag PR #40](https://github.com/mariuszmarzec/caracal-rag/pull/40); merge that change before following this setup. Indexing prefixes document text with `passage:` and MCP search prefixes queries with `query:`. Keep the MCP listener loopback-only; the bearer token is passed to OpenCode through the launcher environment and is never committed to this repository.

# Execution Rules

* Execute sequentially.
* Never skip a step.
* Never assume success.
* Every step MUST finish with a successful healthcheck.
* If a healthcheck fails:
* Enter Self-Healing mode.
* Retry up to three times.
* If still failing, stop and explain the root cause.
* This skill is only active when explicitly invoked for environment setup, installation, or repair.
* Do not apply these rules to normal coding conversations.


* Never overwrite an existing working configuration without creating a backup.

# Success Criteria

* WSL2 operational
* Ubuntu packages installed
* Node.js installed
* Python installed
* Ollama installed and responding
* LiteLLM installed and responding with multiple models available
* Local models installed
* OpenCode configured to see all LiteLLM proxy models
* OpenClaw Gateway installed, connected to LiteLLM, and responding to agent turns
* Test prompt succeeds
* Fallback routing verified
* Caracal RAG installed into ~/.caracal with its own Python virtual environment; the source checkout remains at ~/.caracal-rag
* Caracal has an explicit embedding family, private API key/access token, valid Chroma settings, and a passing `caracal-rag check`
* Both configured knowledge sources (`fiteo-docs` and `quickmvi-readme`) are indexed successfully
* `aicode` starts the authenticated Caracal HTTP MCP after LiteLLM; `opencode mcp list` verifies the connection, and OpenClaw's ACPX `opencode` target points to `~/.globalskills/aicode/opencode-acp-caracal.sh` which repeats the MCP check before starting each ACP harness

# User Interaction Policy

Before installation ask:

1. Which machine is being configured? (Desktop or Laptop)

Do not continue until answered. Detect everything else automatically.

# Communication Protocol for OpenCode

During installation steps, prefer:

```text
STATUS:
Explain current step, previous result and next action.

INTERACTION:
Question for the user or N/A.

COMMAND TO EXECUTE:
Exact bash commands or WAITING.

```

# Hardware Profiles

## Desktop

* CPU: AMD Ryzen 9 5900X
* RAM: 32 GB
* GPU: RTX 3070 8 GB
* Recommended local model:
* `qwen3-coder:14b`
* `qwen3:14b`



## Laptop

* CPU: Intel i7-7700HQ
* RAM: 16 GB
* GPU: GTX 1050 Ti 4 GB
* Recommended local model:
* `qwen2.5-coder:7b`
* `qwen2.5:7b`



> Never install 14B models on the laptop unless explicitly requested.

# Policies

## Agent Decision Policy

* Agent selects the best local model based on the hardware profile.
* Agent configures LiteLLM to expose multiple models: free cloud models (Groq, Cerebras, Gemini, Mistral, OpenRouter) + OpenCode Zen cloud models + local Ollama models.
* Default model is `litellm/big-pickle` (OpenCode Zen, free). Small model is `litellm/groq-llama-8b` (free). Fallback chain: big-pickle → groq-llama-70b → cerebras-gpt-oss-120b → gemini-3.5-flash-lite → mistral-large → or-free → local-coder.

## Multi-Device Sync Policy (Desktop Push to Remote)

When configuring the **Desktop**, the agent MUST push the working LiteLLM configuration to the Laptop (remote):

```bash
# Push config from Desktop to Laptop
scp ~/litellm/config.yaml <laptop-user>@<laptop-ip>:~/litellm/config.yaml
scp ~/litellm/.env <laptop-user>@<laptop-ip>:~/litellm/.env
```

* Desktop is the **source of truth** for LiteLLM config.
* Laptop receives the config but adjusts local model names to match its hardware profile (7B instead of 14B).
* After pushing, always verify the remote LiteLLM instance restarts and healthcheck passes.
* Never push 14B model references to laptop — agent must substitute with 7B equivalents before push.
* All API keys (Groq, Cerebras, Gemini, Mistral, OpenRouter) are shared via `.env` — same keys work on both devices.

## Detection Policy

Automatically detect:

* CPU, RAM, GPU, Disk space
* WSL version, Ubuntu version
* Node, Python, Ollama, LiteLLM

Ask the user only if automatic detection is impossible.

## Idempotency & Self-Healing

* Safe to rerun. Verify first. Repair only if necessary. Retry failed steps up to 3 times.

# Installation Steps

## Step 1 — Update System

**Command**

```bash
sudo apt update && sudo apt upgrade -y && sudo apt install -y curl git jq unzip build-essential python3-pip python3-venv

```

**Healthcheck**

```bash
curl --version
git --version
python3 --version

```

## Step 2 — Install Node.js

```bash
curl -o- [https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh](https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh) | bash
source ~/.bashrc
nvm install --lts
nvm use --lts

```

**Healthcheck:**

```bash
node -v
npm -v

```

## Step 3 — Install OpenCode

Follow the current official installation instructions for OpenCode.

**Healthcheck:**

```bash
opencode --help

```

## Step 4 — Install Ollama

```bash
curl -fsSL [https://ollama.com/install.sh](https://ollama.com/install.sh) | sh

```

**Healthcheck:**

```bash
ollama --version

```

## Step 5 — Start Ollama

```bash
ollama serve

```

**Healthcheck:**

```bash
curl http://localhost:11434/api/tags

```

## Step 6 — Install Local Models

Desktop:

```bash
ollama pull qwen3-coder:14b

```

Laptop:

```bash
ollama pull qwen2.5-coder:7b

```

Caracal RAG embedding model (on each machine):

```bash
ollama pull qllama/multilingual-e5-base

```

**Healthcheck:**

```bash
ollama list

```

## Step 7 — Install LiteLLM

```bash
pip3 install litellm

```

**Healthcheck:**

```bash
litellm --help

```

## Step 8 — Configure LiteLLM

*Agent Note: Adjust the `local-coder` and `gemma4` model names in the YAML below based on the downloaded model from Step 6.*

Create file: `~/litellm/.env`

```bash
LITELLM_MASTER_KEY=sk-12345678
OPENCODE_API_KEY=<YOUR_ZEN_KEY>
GROQ_API_KEY=<YOUR_GROQ_KEY>
CEREBRAS_API_KEY=<YOUR_CEREBRAS_KEY>
GEMINI_API_KEY=<YOUR_GEMINI_KEY>
MISTRAL_API_KEY=<YOUR_MISTRAL_KEY>
OPENROUTER_API_KEY=<YOUR_OPENROUTER_KEY>
```

*Free API keys (no credit card): Groq (console.groq.com), Cerebras (cloud.cerebras.ai), Gemini (aistudio.google.com), Mistral (console.mistral.ai), OpenRouter (openrouter.ai)*

> **Privacy note:** Gemini free tier may use your prompts for training — fine for public/research work, wrong for anything with client or personal data. Groq and Cerebras do not train on your data, so route sensitive work there or to local Ollama models.

Create file: `~/litellm/config.yaml`

```yaml
model_list:

  # ============================================================
  # OpenCode Zen Models
  # ============================================================

  - model_name: big-pickle
    litellm_params:
      model: openai/big-pickle
      api_base: https://opencode.ai/zen/v1
      api_key: os.environ/OPENCODE_API_KEY
      reasoning_effort: none

  - model_name: deepseek-v4-flash-free
    litellm_params:
      model: openai/deepseek-v4-flash-free
      api_base: https://opencode.ai/zen/v1
      api_key: os.environ/OPENCODE_API_KEY

  # ============================================================
  # Groq (fastest free tier, ~320 tok/s)
  # ============================================================

  - model_name: groq-llama-70b
    litellm_params:
      model: groq/llama-3.3-70b-versatile
      api_key: os.environ/GROQ_API_KEY
      max_tokens: 32768

  - model_name: groq-qwen3
    litellm_params:
      model: groq/qwen/qwen3.6-27b
      api_key: os.environ/GROQ_API_KEY
      max_tokens: 32768

  - model_name: groq-llama-8b
    litellm_params:
      model: groq/llama-3.1-8b-instant
      api_key: os.environ/GROQ_API_KEY
      max_tokens: 8192

  # ============================================================
  # Cerebras (fastest inference, ~2600 tok/s)
  # ============================================================

  - model_name: cerebras-gpt-oss-120b
    litellm_params:
      model: cerebras/gpt-oss-120b
      api_key: os.environ/CEREBRAS_API_KEY
      max_tokens: 8192

  - model_name: cerebras-gemma-31b
    litellm_params:
      model: cerebras/gemma-4-31b
      api_key: os.environ/CEREBRAS_API_KEY
      max_tokens: 8192

  - model_name: cerebras-glm-4.7
    litellm_params:
      model: cerebras/zai-glm-4.7
      api_key: os.environ/CEREBRAS_API_KEY
      max_tokens: 8192

  # ============================================================
  # Google Gemini (free tier, per-project limits)
  #   Flash: 5 RPM / 20 RPD | Flash Lite: 15 RPM / 500 RPD
  #   Gemma 4: 30 RPM / 14.4K RPD
  # ============================================================

  - model_name: gemini-3.6-flash
    litellm_params:
      model: gemini/gemini-3.6-flash
      api_key: os.environ/GEMINI_API_KEY
      max_tokens: 8192

  - model_name: gemini-3.5-flash
    litellm_params:
      model: gemini/gemini-3.5-flash
      api_key: os.environ/GEMINI_API_KEY
      max_tokens: 8192

  - model_name: gemini-3.5-flash-lite
    litellm_params:
      model: gemini/gemini-3.5-flash-lite
      api_key: os.environ/GEMINI_API_KEY
      max_tokens: 8192

  - model_name: gemini-3.1-flash-lite
    litellm_params:
      model: gemini/gemini-3.1-flash-lite
      api_key: os.environ/GEMINI_API_KEY
      max_tokens: 8192

  - model_name: gemma-4-31b
    litellm_params:
      model: gemini/gemma-4-31b-it
      api_key: os.environ/GEMINI_API_KEY
      max_tokens: 8192

  - model_name: gemma-4-26b
    litellm_params:
      model: gemini/gemma-4-26b-a4b-it
      api_key: os.environ/GEMINI_API_KEY
      max_tokens: 8192

  # ============================================================
  # Mistral (huge monthly quota, Codestral for code)
  # ============================================================

  - model_name: mistral-large
    litellm_params:
      model: mistral/mistral-large-latest
      api_key: os.environ/MISTRAL_API_KEY

  - model_name: mistral-codestral
    litellm_params:
      model: mistral/codestral-latest
      api_key: os.environ/MISTRAL_API_KEY

  # ============================================================
  # OpenRouter (Free Models Router - auto-picks live :free models)
  # ============================================================

  - model_name: or-free
    litellm_params:
      model: openrouter/openrouter/free
      api_key: os.environ/OPENROUTER_API_KEY

  # ============================================================
  # Local Ollama Models
  # ============================================================

  # Caracal RAG embeddings: 768-dimensional multilingual E5 vectors.
  - model_name: multilingual-e5-base
    litellm_params:
      model: ollama/qllama/multilingual-e5-base
      api_base: http://localhost:11434
      api_key: ollama-local

  - model_name: gemma4
    litellm_params:
      model: ollama/gemma4:12b
      api_base: http://localhost:11434
      api_key: ollama-local
      extra_body:
        num_ctx: 131072

  - model_name: local-coder
    litellm_params:
      model: ollama/gemma4:12b
      api_base: http://localhost:11434
      api_key: ollama-local
      extra_body:
        num_ctx: 131072

# ============================================================
# Router / Fallback
# ============================================================

router_settings:
  fallbacks:
    - big-pickle:
        - groq-llama-70b
        - cerebras-gpt-oss-120b
        - gemini-3.5-flash-lite
        - mistral-large
        - or-free
        - local-coder
    - deepseek-v4-flash-free:
        - groq-llama-70b
        - mistral-codestral
        - or-free
        - local-coder
    - groq-llama-70b:
        - groq-qwen3
        - cerebras-gpt-oss-120b
        - gemini-3.5-flash-lite
        - mistral-large
        - or-free
        - local-coder
    - groq-qwen3:
        - groq-llama-70b
        - cerebras-gpt-oss-120b
        - gemini-3.5-flash-lite
        - or-free
        - local-coder
    - groq-llama-8b:
        - gemini-3.1-flash-lite
        - gemma-4-26b
        - local-coder
    - gemini-3.1-flash-lite:
        - groq-llama-8b
        - gemma-4-26b
        - or-free
        - local-coder
    - gemini-3.6-flash:
        - gemini-3.5-flash
        - groq-llama-70b
        - cerebras-gpt-oss-120b
        - mistral-large
        - or-free
        - local-coder
  allowed_fails: 3

# ============================================================
# LiteLLM Server
# ============================================================

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

# ============================================================
# Proxy
# ============================================================

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: "postgresql://litellm:litellm@127.0.0.1:5432/litellm"
  completion_model: big-pickle
```

**Healthcheck:**

```bash
# Load env vars and start LiteLLM
cd ~/litellm && set -a && source .env && set +a
litellm --config ~/litellm/config.yaml --port 4000 &
sleep 5

# Verify models are registered
curl -fsS http://localhost:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['id']) for m in d['data']]"


# Verify the local embedding route and expected 768-dimensional output.
curl -fsS http://localhost:4000/v1/embeddings \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"multilingual-e5-base","input":"query: Caracal RAG healthcheck"}' | \
  python3 -c "import json,sys; d=json.load(sys.stdin); n=len(d['data'][0]['embedding']); print(f'embedding_dim={n}'); sys.exit(0 if n == 768 else 1)"
```

*Verify that all models are returned: big-pickle, deepseek-v4-flash-free, groq-llama-70b, groq-qwen3, groq-llama-8b, cerebras-gpt-oss-120b, cerebras-gemma-31b, cerebras-glm-4.7, gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemma-4-31b, gemma-4-26b, mistral-large, mistral-codestral, or-free, multilingual-e5-base, gemma4, local-coder.*

### Step 8b — Desktop: Push Config to Remote (Laptop)

**IMPORTANT: Desktop is the source of truth.** When configuring the Desktop, push the LiteLLM config to the Laptop before proceeding:

```bash
# Ensure laptop ~/litellm directory exists
ssh <laptop-user>@<laptop-ip> "mkdir -p ~/litellm"

# Push config and env
scp ~/litellm/config.yaml <laptop-user>@<laptop-ip>:~/litellm/config.yaml
scp ~/litellm/.env <laptop-user>@<laptop-ip>:~/litellm/.env

# IMPORTANT: Before pushing, substitute 14B model refs with 7B for laptop
# The agent MUST edit the remote config to use qwen2.5-coder:7b instead of qwen3-coder:14b
ssh <laptop-user>@<laptop-ip> "sed -i 's/qwen3-coder:14b/qwen2.5-coder:7b/g; s/qwen3:14b/qwen2.5:7b/g' ~/litellm/config.yaml"

# Restart LiteLLM on laptop
ssh <laptop-user>@<laptop-ip> "pkill -f litellm; nohup litellm --config ~/litellm/config.yaml --port 4000 >/tmp/litellm.log 2>&1 &"

# Verify remote healthcheck
ssh <laptop-user>@<laptop-ip> "cd ~/litellm && set -a && source .env && set +a && curl -fsS http://localhost:4000/v1/models -H \"Authorization: Bearer \\$LITELLM_MASTER_KEY\""

```

*Skip this step when configuring the Laptop directly.*

### Step 8c — Install globalskills (agents + skills)

The environment ships with shared skills (`~/.globalskills/skills`) and OpenCode agents (`~/.globalskills/agents`). OpenCode only reads agents from `~/.config/opencode/agents/`, so they must be symlinked — `install.sh` does this automatically. This must run on **every** machine (Desktop and Laptop) before configuring OpenCode.

```bash
# Clone or update the globalskills repo
if [ -d ~/.globalskills ]; then
  git -C ~/.globalskills pull --ff-only
else
  git clone git@github.com:mariuszmarzec/globalskills.git ~/.globalskills \
    || git clone https://github.com/mariuszmarzec/globalskills.git ~/.globalskills
fi

# Create skills + agents symlinks (~/.agents/skills, ~/.config/opencode/agents)
bash ~/.globalskills/install.sh
```

**Healthcheck:**

```bash
test -e ~/.config/opencode/agents/orchestrator.md && echo "agents OK"
test -e ~/.agents/skills/wsl-ai-dev-autopilot-multi-device/SKILL.md && echo "skills OK"
```

*If SSH fails on a fresh machine (no key deployed), fall back to the HTTPS clone URL shown above.*


### Step 8d — Install and configure Caracal RAG (Desktop and Laptop)

Caracal is installed on each machine using its repository installer. This creates an isolated environment under `~/.caracal` and preserves existing configuration, secrets, and index state. Do not use a system-wide `pip install`.

```bash
CARACAL_REPO="$HOME/.caracal-rag"
if [ -e "$CARACAL_REPO" ]; then
  if [ ! -d "$CARACAL_REPO/.git" ]; then
    echo "ERROR: $CARACAL_REPO exists but is not a Git checkout; preserve it and inspect the path."
    exit 1
  fi
  if [ -n "$(git -C "$CARACAL_REPO" status --porcelain)" ]; then
    echo "ERROR: Caracal checkout has local changes. Commit/stash them or review before updating."
    git -C "$CARACAL_REPO" status --short
    exit 1
  fi
  git -C "$CARACAL_REPO" pull --ff-only
else
  git clone git@github.com:mariuszmarzec/caracal-rag.git "$CARACAL_REPO" \
    || git clone https://github.com/mariuszmarzec/caracal-rag.git "$CARACAL_REPO"
fi

cd "$CARACAL_REPO"
bash ./install.sh
export PATH="$HOME/.caracal/bin:$PATH"

# Back up the existing local config/secrets/manifest before switching embedding models.
# This local backup does not include Chroma vector data.
if [ -f "$HOME/.caracal/config/sources.yaml" ]; then
  bash "$CARACAL_REPO/backup.sh" --output "$HOME/caracal-backups/pre-multilingual-e5-config-$(date -u +%Y%m%dT%H%M%SZ)"
fi
```

Configure Caracal to use the local E5 alias through LiteLLM. Load the master key from the private LiteLLM `.env` file; do not put the key in shell history or process arguments:

```bash
cd "$HOME/litellm" && set -a && source .env && set +a
export CARACAL_EMBEDDING_API_KEY="$LITELLM_MASTER_KEY"
"$HOME/.caracal/bin/caracal-rag" setup --model multilingual-e5-base --api-base http://127.0.0.1:4000/v1
unset CARACAL_EMBEDDING_API_KEY
```

The active config should use `embedding.model: multilingual-e5-base` and `embedding.api_base: http://127.0.0.1:4000/v1`. The LiteLLM master key is persisted as Caracal's embedding API key; the Caracal MCP access token remains separate. Confirm `~/.caracal/config/sources.yaml` points to Chroma at `127.0.0.1:3400` and includes both knowledge sources:

- `fiteo-docs` — API Markdown documents from `mariuszmarzec/fiteo/docs/api/` on `master`.
- `quickmvi-readme` — `https://raw.githubusercontent.com/mariuszmarzec/QuickMVI/develop/README.md`, covering QuickMVI library usage at README level.

The installer preserves an existing `sources.yaml`; updating `config/sources.example.yaml` does not merge new sources into an already-installed config. If `quickmvi-readme` is missing, add this item under the existing `sources:` list (do not create a duplicate `sources:` key):

```yaml
  - name: quickmvi-readme
    type: markdown
    url: https://raw.githubusercontent.com/mariuszmarzec/QuickMVI/develop/README.md
```

Defaults in the template are LiteLLM at `http://127.0.0.1:4000/v1`, Chroma at `127.0.0.1:3400`, and MCP at `127.0.0.1:3500/mcp`. The `multilingual-e5-base` alias is a separate LiteLLM entry routed to Ollama, not a chat-completion fallback.

Use the backup created before `setup` above, then use the confirmation-gated block below to clear only the active Caracal collection and its manifest. The backup does not include Chroma vector data; clearing the collection is destructive.

```bash
export CARACAL_HOME="$HOME/.caracal"
"$HOME/.caracal/venv/bin/python" - <<'PY'
from caracal_rag.config import load_active_config, resolve_home
from caracal_rag.vectorstore import _chroma_client

config = load_active_config()
client = _chroma_client(host=config.chroma.host, port=config.chroma.port, ssl=config.chroma.ssl)
listed = client.list_collections()
names = {item if isinstance(item, str) else item.name for item in listed}
collection_name = config.chroma.collection
count = client.get_collection(name=collection_name).count() if collection_name in names else 0
print(f"Target collection: {collection_name}; current vector count: {count}")
if input(f"Type DELETE {collection_name} to continue: ").strip() != f"DELETE {collection_name}":
    raise SystemExit("Cancelled; no collection or manifest was deleted.")
if collection_name in names:
    client.delete_collection(name=collection_name)
manifest_path = resolve_home().manifest_path
if manifest_path.exists():
    manifest_path.unlink()
print("Old Caracal collection and manifest cleared.")
PY
```

For a first-time install with no existing index, skip the destructive block. After the reset, `check` should pass and report 768 dimensions, then `index` rebuilds the configured knowledge sources. Confirm `search_api` returns relevant documents before considering migration complete.

```bash
"$HOME/.caracal/bin/caracal-rag" check
"$HOME/.caracal/bin/caracal-rag" index
"$HOME/.caracal/bin/caracal-rag" check
```

After indexing, restart the existing Caracal MCP process so it reloads the new model/config. The launcher only trusts its own PID when the command line and configured port/path match; use the same ownership check here and do not use `pkill -f`:

```bash
CARACAL_PID_FILE="$HOME/.caracal/run/mcp.pid"
if [ -f "$CARACAL_PID_FILE" ]; then
  pid="$(cat "$CARACAL_PID_FILE")"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid Caracal PID file; inspect $CARACAL_PID_FILE" >&2
    exit 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    cmd="$(tr "\0" " " < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cmd" != *"caracal-rag mcp --transport http"* || "$cmd" != *"--port 3500"* || "$cmd" != *"--path /mcp"* ]]; then
      echo "ERROR: refusing to stop a process that does not match the configured Caracal MCP command." >&2
      exit 1
    fi
    kill -TERM "$pid"
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: Caracal MCP did not stop; inspect PID $pid." >&2
      exit 1
    fi
  fi
  rm -f -- "$CARACAL_PID_FILE"
fi
# Run the normal environment launcher to start MCP against the new index.
aicode
```

**Healthcheck:** both `check` calls succeed, indexing completes, and `~/.caracal/config/secrets.yaml` has mode `0600`. Do not start MCP or claim setup is complete if credentials, embedding-model validation, or Chroma connectivity fails; fix the reported dependency and rerun the check.

The authenticated MCP server is launched by `aicode` after LiteLLM. Keep `mcp.host: 127.0.0.1`; never expose the token-authenticated listener on a public interface. The launcher tracks only its own PID in `~/.caracal/run/mcp.pid`, logs to `/tmp/caracal-mcp.log`, and does not kill an unknown process that happens to use the configured port.

## Step 9 — Configure OpenCode

`~/.config/opencode/opencode.json`

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "litellm/big-pickle",
  "small_model": "litellm/groq-llama-8b",
  "skills": { 
    "paths": ["~/.globalskills/skills"] 
  },
  "mcp": {
    "caracal-rag": {
      "type": "remote",
      "url": "{env:CARACAL_MCP_URL}",
      "oauth": false,
      "enabled": true,
      "headers": {
        "Authorization": "Bearer {env:CARACAL_ACCESS_TOKEN}"
      }
    }
  },
  "permission": {
    "external_directory": {
      "~/litellm/**": "allow",
      "~/.config/opencode/**": "allow",
      "~/.globalskills/**": "allow"
    }
  },
  "agent": {
    "chat": {
      "description": "Standard conversational chat without tools",
      "mode": "primary",
      "tools": {
        "*": false
      },
      "permission": {
        "*": "deny"
      },
      "prompt": "You are a helpful AI coding assistant. Respond directly in natural language and standard Markdown. Do not attempt to use any tools, and do NOT format your responses as JSON."
    }
  },
  "provider": {
    "opencode": {
      "options": {
        "apiKey": "{env:OPENCODE_API_KEY}"
      }
    },
    "ollama": {
      "id": "ollama",
      "api": "openai",
      "name": "Ollama Local",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {
        "gemma4:12b": {
          "id": "gemma4:12b",
          "name": "Gemma 4 12B (Ollama)",
          "family": "gemma",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 32768, "output": 32768 }
        }
      }
    },
    "litellm": {
      "id": "litellm",
      "api": "openai",
      "name": "LiteLLM Proxy",
      "options": {
        "baseURL": "http://localhost:4000/v1",
        "apiKey": "sk-12345678"
      },
      "models": {
        "big-pickle": {
          "id": "big-pickle",
          "name": "Big Pickle (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 65536 }
        },
        "deepseek-v4-flash-free": {
          "id": "deepseek-v4-flash-free",
          "name": "DeepSeek V4 Flash Free (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 65536 }
        },
        "groq-llama-70b": {
          "id": "groq-llama-70b",
          "name": "Llama 3.3 70B (Groq, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 32000 }
        },
        "groq-qwen3": {
          "id": "groq-qwen3",
          "name": "Qwen3.6 27B (Groq, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 32000 }
        },
        "groq-llama-8b": {
          "id": "groq-llama-8b",
          "name": "Llama 3.1 8B (Groq, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 8192 }
        },
        "cerebras-gpt-oss-120b": {
          "id": "cerebras-gpt-oss-120b",
          "name": "GPT-OSS 120B (Cerebras, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 8192, "output": 8192 }
        },
        "cerebras-gemma-31b": {
          "id": "cerebras-gemma-31b",
          "name": "Gemma 4 31B (Cerebras, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 8192, "output": 8192 }
        },
        "cerebras-glm-4.7": {
          "id": "cerebras-glm-4.7",
          "name": "GLM 4.7 (Cerebras, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 8192, "output": 8192 }
        },
        "gemini-3.6-flash": {
          "id": "gemini-3.6-flash",
          "name": "Gemini 3.6 Flash (Google, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 1048576, "output": 8192 }
        },
        "gemini-3.5-flash": {
          "id": "gemini-3.5-flash",
          "name": "Gemini 3.5 Flash (Google, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 1048576, "output": 8192 }
        },
        "gemini-3.5-flash-lite": {
          "id": "gemini-3.5-flash-lite",
          "name": "Gemini 3.5 Flash Lite (Google, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 1048576, "output": 8192 }
        },
        "gemini-3.1-flash-lite": {
          "id": "gemini-3.1-flash-lite",
          "name": "Gemini 3.1 Flash Lite (Google, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 1048576, "output": 8192 }
        },
        "gemma-4-31b": {
          "id": "gemma-4-31b",
          "name": "Gemma 4 31B (Google, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 131072, "output": 8192 }
        },
        "gemma-4-26b": {
          "id": "gemma-4-26b",
          "name": "Gemma 4 26B (Google, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 131072, "output": 8192 }
        },
        "mistral-large": {
          "id": "mistral-large",
          "name": "Mistral Large (Mistral, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 32000 }
        },
        "mistral-codestral": {
          "id": "mistral-codestral",
          "name": "Codestral (Mistral, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 256000, "output": 32000 }
        },
        "or-free": {
          "id": "or-free",
          "name": "Free Models Router (OpenRouter, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 200000, "output": 32000 }
        },
        "gemma4": {
          "id": "gemma4",
          "name": "Gemma 4 12B Local (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 131072, "output": 32000 }
        },
        "local-coder": {
          "id": "local-coder",
          "name": "Local Coder (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 131072, "output": 32000 }
        }
      }
    }
  }
}
```

*Note: This configuration provides three providers:*
- *`opencode/` - Direct access to OpenCode Zen cloud models*
- *`litellm/` - All models via LiteLLM proxy (20+ free cloud models + local)*
- *`ollama/` - Direct access to local Ollama models*
- *Default model: `litellm/big-pickle` (OpenCode Zen, free). Fallback: groq → cerebras → gemini → mistral → openrouter → local-coder.*

**Healthcheck:**
Execute a test prompt to verify connection.

## Step 10 — Install & Configure OpenClaw

OpenClaw is the open-source personal AI assistant gateway (https://openclaw.ai). It runs one Gateway process that serves a Control UI dashboard, a TUI/CLI, and optional chat channels (Telegram, WhatsApp, Slack, Discord, etc.). It connects to LiteLLM as a custom OpenAI-compatible provider, so all LiteLLM models are available. Requires Node 22.22.3+, 24.15+, or 25.9+.

```bash
npm install -g openclaw@latest
openclaw --version
```

**Healthcheck:**
```bash
openclaw --version
```

Create `~/.openclaw/openclaw.json` (JSON5). The provider id is `litellm`, pointing at the local proxy. Model metadata (contextWindow/maxTokens) should mirror the model's real limits; `reasoning: false` unless the model supports it.

```json5
{
  models: {
    providers: {
      litellm: {
        baseUrl: "http://localhost:4000/v1",
        apiKey: "sk-12345678", // LITELLM_MASTER_KEY from ~/litellm/.env
        api: "openai-completions",
        timeoutSeconds: 300,
        models: [
          { id: "big-pickle", name: "Big Pickle (Zen, free)", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 65536 },
          { id: "deepseek-v4-flash-free", name: "DeepSeek V4 Flash Free (Zen)", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 65536 },
          { id: "groq-llama-70b", name: "Llama 3.3 70B (Groq, free)", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 8192 },
          { id: "groq-qwen3", name: "Qwen3.6 27B (Groq, free)", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 8192 },
          { id: "groq-llama-8b", name: "Llama 3.1 8B (Groq, free)", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 8192 },
          { id: "cerebras-gpt-oss-120b", name: "GPT-OSS 120B (Cerebras, free)", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 8192 },
          { id: "cerebras-gemma-31b", name: "Gemma 4 31B (Cerebras, free)", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 8192 },
          { id: "cerebras-glm-4.7", name: "GLM 4.7 (Cerebras, free)", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 8192 },
          { id: "gemini-3.6-flash", name: "Gemini 3.6 Flash (Google, free)", reasoning: true, input: ["text"], contextWindow: 1048576, maxTokens: 8192 },
          { id: "gemini-3.5-flash", name: "Gemini 3.5 Flash (Google, free)", reasoning: true, input: ["text"], contextWindow: 1048576, maxTokens: 8192 },
          { id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash Lite (Google, free)", reasoning: true, input: ["text"], contextWindow: 1048576, maxTokens: 8192 },
          { id: "gemini-3.1-flash-lite", name: "Gemini 3.1 Flash Lite (Google, free)", reasoning: true, input: ["text"], contextWindow: 1048576, maxTokens: 8192 },
          { id: "gemma-4-31b", name: "Gemma 4 31B (Google, free)", reasoning: false, input: ["text"], contextWindow: 131072, maxTokens: 8192 },
          { id: "gemma-4-26b", name: "Gemma 4 26B (Google, free)", reasoning: false, input: ["text"], contextWindow: 131072, maxTokens: 8192 },
          { id: "mistral-large", name: "Mistral Large (free)", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 8192 },
          { id: "mistral-codestral", name: "Codestral (free)", reasoning: false, input: ["text"], contextWindow: 256000, maxTokens: 8192 },
          { id: "or-free", name: "Free Models Router (OpenRouter)", reasoning: false, input: ["text"], contextWindow: 200000, maxTokens: 65536 },
          { id: "gemma4", name: "Gemma 4 12B Local (Ollama)", reasoning: false, input: ["text"], contextWindow: 131072, maxTokens: 4096 },
          { id: "local-coder", name: "Local Coder (Ollama)", reasoning: false, input: ["text"], contextWindow: 131072, maxTokens: 4096 },
        ],
      },
    },
  },
  agents: {
    defaults: {
      model: { primary: "litellm/groq-llama-70b" },
    },
  },
}
```

Configure local Gateway mode + a persistent auth token (avoids the runtime-generated token that breaks WS probes):

```bash
openclaw config set gateway.mode local
openclaw config set gateway.auth.mode token
openclaw config set gateway.auth.token sk-openclaw-local
openclaw config validate
```

**Healthcheck:**
```bash
nohup openclaw gateway --force --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
sleep 8
openclaw gateway status | grep -i connectivity   # expect: ok
openclaw models list                              # expect: 23 litellm/ models listed
# IMPORTANT: use a dedicated --session-key. Routing to --agent main hangs while
# the main session is busy (the turn just queues). A separate session answers instantly:
openclaw agent --agent main --session-key healthcheck -m "Reply with exactly: LiteLLM connection OK" --model litellm/groq-llama-70b
# expect reply: LiteLLM connection OK
```

*Note: If the gateway blocks on `missing gateway.mode`, set `gateway.mode=local` as above. Use `openclaw dashboard` for the browser UI and `openclaw chat` for the terminal TUI.*

# Daily Startup Script

The maintained launcher is `~/.globalskills/aicode/aicode`; `install.sh` links it to `~/.aicode/aicode`. Avoid maintaining a divergent copied launcher. If an existing file occupies that path, the installer preserves it in a timestamped backup before linking the maintained version.

On each startup, `aicode` starts/validates LiteLLM first, then validates Caracal and starts its authenticated HTTP MCP on loopback only when `caracal-rag check` passes. It configures the canonical OpenCode entry `mcp["caracal-rag"]` and points OpenClaw's ACPX `opencode` harness at `~/.globalskills/aicode/opencode-acp-caracal.sh`. It also sets `plugins.entries.acpx.config.probeAgent: "opencode"` so ACPX startup healthchecks validate this exact harness. Before each ACP session, the wrapper resolves the current local endpoint/token, exports `CARACAL_MCP_URL`, `CARACAL_ACCESS_TOKEN` and `OPENCODE_CONFIG`, and requires `opencode mcp list` to report Caracal connected before it executes `opencode acp`. This keeps the configuration on the process that actually owns Caracal tools and avoids duplicating Caracal as a native OpenClaw MCP server. The ACPX plugin must already be enabled. If Caracal is unavailable, the config is missing, or the live probe fails, the launcher or ACP wrapper stops instead of starting a partially configured agent. The launcher reuses a healthy Caracal process only when the PID file and command line prove it owns that process; it will not kill an unrelated process or send credentials to an unverified endpoint. See `/tmp/caracal-mcp.log` for startup errors.

```bash
bash ~/.globalskills/install.sh
grep -qF "alias aicode='~/.aicode/aicode'" ~/.bashrc || echo "alias aicode='~/.aicode/aicode'" >> ~/.bashrc
source ~/.bashrc
aicode
```

# FreeLLMAPI integration

This skill supports using FreeLLMAPI as a local unified cloud-provider router for LiteLLM. Use this when you want to aggregate multiple cloud providers behind a single local API to simplify routing and key management.

- Deploy FreeLLMAPI locally (Docker / docker-compose) and bind it to loopback only (`127.0.0.1:3001`).
- Add provider keys in the FreeLLMAPI dashboard and generate the unified `FREELLMAPI_API_KEY`.
- Store the unified key in `~/litellm/.env` as `FREELLMAPI_API_KEY` and load it into the environment when starting `litellm` (use `set -a; source ~/litellm/.env; set +a`).
- Add a `free-cloud` provider entry in `~/litellm/config.yaml` that points at `http://127.0.0.1:3001/v1` and uses `api_key: os.environ/FREELLMAPI_API_KEY`.
- Verification quickchecks:
  - `curl -H "Authorization: Bearer $FREELLMAPI_API_KEY" http://127.0.0.1:3001/v1/models` — confirm FreeLLMAPI catalog.
  - Start or restart LiteLLM with the env loaded and confirm `curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:4000/v1/models` lists `free-cloud`.

See the dedicated skill for operational guidance and security best practices: `~/.globalskills/skills/freellmapi-environment/SKILL.md`.

# Final Validation

Verify:

* Ollama responds.
* LiteLLM responds and exposes all models (big-pickle, deepseek-v4-flash-free, groq-llama-70b, groq-qwen3, groq-llama-8b, cerebras-gpt-oss-120b, cerebras-gemma-31b, cerebras-glm-4.7, gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemma-4-31b, gemma-4-26b, mistral-large, mistral-codestral, or-free, gemma4, local-coder).
* OpenCode shows all three providers (opencode, litellm, ollama).
* OpenClaw Gateway responds on ws://127.0.0.1:18789, lists 23 `litellm/` models, and answers an agent turn through LiteLLM.
* Primary routing works (big-pickle via LiteLLM).
* Fallback routing works: big-pickle → groq-llama-70b → cerebras-gpt-oss-120b → gemini-3.5-flash-lite → mistral-large → or-free → local-coder.
* Startup script loads all API keys from `~/litellm/.env`.
* OpenCode agents symlinked and readable (`~/.config/opencode/agents/orchestrator.md`).
* Shared skills symlinked (`~/.agents/skills/wsl-ai-dev-autopilot-multi-device/SKILL.md`).
* Caracal `check` and Fiteo source indexing succeed; the authenticated MCP responds on the configured loopback URL.
* `opencode mcp list` reports `caracal-rag` connected when launched through `aicode`.
* The OpenClaw ACPX config points the `opencode` harness at `~/.globalskills/aicode/opencode-acp-caracal.sh`.
* The ACP wrapper verifies Caracal using the current secret and effective OpenCode config, then starts `opencode acp`; a disconnected MCP must prevent ACP startup.
* The Manul OpenCode adapter injects Caracal into its task-local config and refuses to start the task if `opencode mcp list` does not report a live connection.

Only then report:

> Installation completed successfully. You have 20+ models available via LiteLLM from 6 providers (Groq, Cerebras, Gemini, Mistral, OpenRouter, OpenCode Zen) plus local Ollama models. OpenClaw's default model is `litellm/groq-llama-70b` (free); OpenCode's default remains `litellm/big-pickle` (free). Fallback chain ensures free models are used if Zen is unavailable. Multi-agent orchestration (orchestrator + 14 subagents) is installed and free-only. Switch models anytime in the OpenCode UI or the OpenClaw Control UI.