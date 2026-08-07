---
name: wsl-ai-dev-autopilot-multi-device
description: Fully automated WSL2 AI dev environment (OpenCode + OpenClaw compatible). Supports multi-device installation (PC + laptop). Includes hardware-aware model selection, strict healthchecks, self-healing loop, and multi-model LiteLLM routing across 6+ free providers (Groq, Cerebras, Gemini, Mistral, OpenRouter, OpenCode Zen) plus local Ollama. Use when setting up or repairing a WSL2 AI dev environment with Ollama, LiteLLM, OpenCode, and OpenClaw.
---

# WSL AI Dev Autopilot Skill

# Purpose

This skill guides an AI agent through the complete installation and validation of an AI development environment on WSL2. It configures LiteLLM as a proxy exposing 20+ models from 7 sources to the OpenCode TUI and the OpenClaw Gateway, allowing the user to select cloud models (with fallback), strictly cloud, or strictly local models.

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
        │       ├── deepseek-v4-flash-free (Free)
        │       ├── claude-sonnet-4-5 (Paid)
        │       ├── claude-haiku-4-5 (Paid)
        │       ├── gpt-5.2 (Paid)
        │       └── gpt-5.1-codex (Paid)
        │
        └── Local Ollama Models
            ├── gemma4 (gemma4:12b)
            └── local-coder (Fallback)
```

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
* Default model is `litellm/big-pickle` (OpenCode Zen, paid). Small model is `litellm/groq-llama-8b` (free). Fallback chain: big-pickle → groq-llama-70b → cerebras-gpt-oss-120b → gemini-3.5-flash-lite → mistral-large → or-free → local-coder.

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
sudo apt update && sudo apt upgrade -y && sudo apt install -y curl git jq unzip build-essential python3-pip

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
      max_tokens: 16384
      reasoning_effort: none

  - model_name: claude-sonnet-4-5
    litellm_params:
      model: anthropic/claude-sonnet-4-5
      api_base: https://opencode.ai/zen/v1
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  - model_name: claude-haiku-4-5
    litellm_params:
      model: anthropic/claude-haiku-4-5
      api_base: https://opencode.ai/zen/v1
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  - model_name: gpt-5.2
    litellm_params:
      model: openai/gpt-5.2
      api_base: https://opencode.ai/zen/v1
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  - model_name: gpt-5.1-codex
    litellm_params:
      model: openai/gpt-5.1-codex
      api_base: https://opencode.ai/zen/v1
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  - model_name: deepseek-v4-flash-free
    litellm_params:
      model: openai/deepseek-v4-flash-free
      api_base: https://opencode.ai/zen/v1
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  # ============================================================
  # Groq (fastest free tier, ~320 tok/s)
  # ============================================================

  - model_name: groq-llama-70b
    litellm_params:
      model: groq/llama-3.3-70b-versatile
      api_key: os.environ/GROQ_API_KEY
      max_tokens: 8192

  - model_name: groq-qwen3
    litellm_params:
      model: groq/qwen/qwen3.6-27b
      api_key: os.environ/GROQ_API_KEY
      max_tokens: 8192

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
      max_tokens: 8192

  - model_name: mistral-codestral
    litellm_params:
      model: mistral/codestral-latest
      api_key: os.environ/MISTRAL_API_KEY
      max_tokens: 8192

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

  - model_name: gemma4
    litellm_params:
      model: ollama/gemma4:12b
      api_base: http://localhost:11434
      api_key: ollama-local
      max_tokens: 4096
      extra_body:
        num_ctx: 131072

  - model_name: local-coder
    litellm_params:
      model: ollama/gemma4:12b
      api_base: http://localhost:11434
      api_key: ollama-local
      max_tokens: 4096
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
  master_key: sk-12345678
  completion_model: big-pickle
```

**Healthcheck:**

```bash
# Load env vars and start LiteLLM
cd ~/litellm && set -a && source .env && set +a
litellm --config ~/litellm/config.yaml --port 4000 &
sleep 5

# Verify models are registered
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer sk-12345678" | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['id']) for m in d['data']]"
```

*Verify that all models are returned: big-pickle, deepseek-v4-flash-free, groq-llama-70b, groq-qwen3, groq-llama-8b, cerebras-gpt-oss-120b, cerebras-gemma-31b, cerebras-glm-4.7, gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemma-4-31b, gemma-4-26b, mistral-large, mistral-codestral, or-free, gemma4, local-coder.*

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
ssh <laptop-user>@<laptop-ip> "curl -s http://localhost:4000/v1/models -H 'Authorization: Bearer sk-12345678'"
```

*Skip this step when configuring the Laptop directly.*

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
          "limit": { "context": 128000, "output": 16384 }
        },
        "deepseek-v4-flash-free": {
          "id": "deepseek-v4-flash-free",
          "name": "DeepSeek V4 Flash Free (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 16384 }
        },
        "groq-llama-70b": {
          "id": "groq-llama-70b",
          "name": "Llama 3.3 70B (Groq, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 8192 }
        },
        "groq-qwen3": {
          "id": "groq-qwen3",
          "name": "Qwen3.6 27B (Groq, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 8192 }
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
          "limit": { "context": 128000, "output": 8192 }
        },
        "mistral-codestral": {
          "id": "mistral-codestral",
          "name": "Codestral (Mistral, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 256000, "output": 8192 }
        },
        "or-free": {
          "id": "or-free",
          "name": "Free Models Router (OpenRouter, free)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 200000, "output": 65536 }
        },
        "gemma4": {
          "id": "gemma4",
          "name": "Gemma 4 12B Local (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 131072, "output": 4096 }
        },
        "local-coder": {
          "id": "local-coder",
          "name": "Local Coder (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 131072, "output": 4096 }
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
- *Default model: `litellm/big-pickle` (OpenCode Zen, paid). Fallback: groq → cerebras → gemini → mistral → openrouter → local-coder.*

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
          { id: "big-pickle", name: "Big Pickle (Zen, paid)", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 16384 },
          { id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5 (Zen)", reasoning: true, input: ["text"], contextWindow: 200000, maxTokens: 16384 },
          { id: "claude-haiku-4-5", name: "Claude Haiku 4.5 (Zen)", reasoning: true, input: ["text"], contextWindow: 200000, maxTokens: 16384 },
          { id: "gpt-5.2", name: "GPT-5.2 (Zen)", reasoning: true, input: ["text"], contextWindow: 128000, maxTokens: 16384 },
          { id: "gpt-5.1-codex", name: "GPT-5.1 Codex (Zen)", reasoning: true, input: ["text"], contextWindow: 128000, maxTokens: 16384 },
          { id: "deepseek-v4-flash-free", name: "DeepSeek V4 Flash Free (Zen)", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 16384 },
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

`~/.aicode/aicode`

```bash
#!/bin/bash
# aicode - Start AI dev environment and launch OpenCode

export PATH="$HOME/.opencode/bin:$PATH"

if [ -f "$HOME/.config/opencode/opencode.env" ]; then
    set -a
    . "$HOME/.config/opencode/opencode.env"
    set +a
fi

if [ -z "${OPENCODE_API_KEY:-}" ]; then
    echo "OPENCODE_API_KEY is not set; OpenCode Zen will be unavailable until you add it to ~/.config/opencode/opencode.env."
fi

# Ensure Ollama is running
if ! pgrep -x "ollama" > /dev/null; then
    nohup ollama serve > /tmp/ollama.log 2>&1 &
    sleep 3
fi

# Ensure PostgreSQL is available for LiteLLM UI/auth
if command -v pg_isready >/dev/null 2>&1; then
    if ! pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
        if command -v service >/dev/null 2>&1; then
            sudo service postgresql start >/dev/null 2>&1 || true
        fi
        if command -v pg_ctlcluster >/dev/null 2>&1; then
            pg_ctlcluster 12 main start >/dev/null 2>&1 || true
        fi
        sleep 3
    fi
    if pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
        if ! sudo -n -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw 'litellm' 2>/dev/null; then
            sudo -u postgres psql -c "CREATE USER litellm WITH PASSWORD 'litellm';" >/dev/null 2>&1 || true
            sudo -u postgres psql -c "CREATE DATABASE litellm OWNER litellm;" >/dev/null 2>&1 || true
        fi
    fi
fi

# Ensure LiteLLM is running (with all API keys loaded)
if ! pgrep -f "litellm" > /dev/null; then
    if [ -f "$HOME/litellm/.env" ]; then
        set -a
        . "$HOME/litellm/.env"
        set +a
    fi
    nohup litellm --config "$HOME/litellm/config.yaml" --port 4000 > /tmp/litellm.log 2>&1 &
    sleep 3
fi

# Ensure OpenClaw Gateway is running (serves all LiteLLM models too)
if ! pgrep -f "openclaw gateway" > /dev/null; then
    nohup openclaw gateway --force --port 18789 > /tmp/openclaw-gateway.log 2>&1 &
    sleep 3
fi

# Ensure manul GitHub bot daemon is running (polls /manul comments on watched repos)
# Idempotent: start is a no-op when the daemon is already up.
"$HOME/.openclaw/manul/manul-daemon.sh" start >/dev/null 2>&1

# Launch OpenCode
if [ -n "${OPENCODE_API_KEY:-}" ]; then
    echo "OpenCode Zen API key detected; all Zen models available."
else
    echo "No OPENCODE_API_KEY detected; Zen models unavailable."
fi
echo "Free cloud models: Groq, Cerebras, Gemini, Mistral, OpenRouter"
echo "Local model via LiteLLM: litellm/local-coder (Gemma 4 12B)"
echo "OpenClaw Gateway: http://127.0.0.1:18789 (openclaw chat / openclaw dashboard)"

exec opencode "$@"
```

```bash
mkdir -p ~/.aicode
chmod +x ~/.aicode/aicode
echo "alias aicode='~/.aicode/aicode'" >> ~/.bashrc
source ~/.bashrc

```

# Final Validation

Verify:

* Ollama responds.
* LiteLLM responds and exposes all models (big-pickle, deepseek-v4-flash-free, groq-llama-70b, groq-qwen3, groq-llama-8b, cerebras-gpt-oss-120b, cerebras-gemma-31b, cerebras-glm-4.7, gemini-3.6-flash, gemini-3.5-flash, gemini-3.5-flash-lite, gemini-3.1-flash-lite, gemma-4-31b, gemma-4-26b, mistral-large, mistral-codestral, or-free, gemma4, local-coder).
* OpenCode shows all three providers (opencode, litellm, ollama).
* OpenClaw Gateway responds on ws://127.0.0.1:18789, lists 23 `litellm/` models, and answers an agent turn through LiteLLM.
* Primary routing works (big-pickle via LiteLLM).
* Fallback routing works: big-pickle → groq-llama-70b → cerebras-gpt-oss-120b → gemini-3.5-flash-lite → mistral-large → or-free → local-coder.
* Startup script loads all API keys from `~/litellm/.env`.

Only then report:

> Installation completed successfully. You have 20+ models available via LiteLLM from 6 providers (Groq, Cerebras, Gemini, Mistral, OpenRouter, OpenCode Zen) plus local Ollama models. OpenClaw's default model is `litellm/groq-llama-70b` (free); OpenCode's default remains `litellm/big-pickle` (paid). Fallback chain ensures free models are used if Zen is unavailable. Switch models anytime in the OpenCode UI or the OpenClaw Control UI.