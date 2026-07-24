---
name: wsl-ai-dev-autopilot-multi-device
description: Fully automated WSL2 AI dev environment (OpenCode compatible). Supports multi-device installation (PC + laptop). Includes hardware-aware model selection, strict healthchecks, self-healing loop, and multi-model LiteLLM routing (big-pickle, zen models, local-coder). Use when setting up or repairing a WSL2 AI dev environment with Ollama, LiteLLM, and OpenCode.
---

# WSL AI Dev Autopilot Skill

# Purpose

This skill guides an AI agent through the complete installation and validation of an AI development environment on WSL2. It configures LiteLLM as a proxy exposing multiple models to the OpenCode TUI, allowing the user to select cloud models (with fallback), strictly cloud, or strictly local models.

## Architecture

```text
OpenCode Client
        │
        ▼
LiteLLM (Router & Proxy - Port 4000)
        │
        ├── OpenCode Zen Models (Cloud)
        │   ├── big-pickle (Free)
        │   ├── claude-sonnet-4-5
        │   ├── claude-haiku-4-5
        │   ├── gpt-5.2
        │   ├── gpt-5.1-codex
        │   └── deepseek-v4-flash-free (Free)
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
* Agent configures LiteLLM to expose multiple models: OpenCode Zen cloud models + local Ollama models.

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

Create file: `~/litellm/config.yaml`

```yaml
model_list:
  # === OpenCode Zen Models ===
  - model_name: big-pickle
    litellm_params:
      model: openai/big-pickle
      api_base: https://opencode.ai/zen/v1/chat/completions
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  - model_name: claude-sonnet-4-5
    litellm_params:
      model: openai/claude-sonnet-4-5
      api_base: https://opencode.ai/zen/v1/messages
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  - model_name: claude-haiku-4-5
    litellm_params:
      model: openai/claude-haiku-4-5
      api_base: https://opencode.ai/zen/v1/messages
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  - model_name: gpt-5.2
    litellm_params:
      model: openai/gpt-5.2
      api_base: https://opencode.ai/zen/v1/responses
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  - model_name: gpt-5.1-codex
    litellm_params:
      model: openai/gpt-5.1-codex
      api_base: https://opencode.ai/zen/v1/responses
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  - model_name: deepseek-v4-flash-free
    litellm_params:
      model: openai/deepseek-v4-flash-free
      api_base: https://opencode.ai/zen/v1/chat/completions
      api_key: os.environ/OPENCODE_API_KEY
      max_tokens: 16384

  # === Local Ollama Models ===
  - model_name: gemma4
    litellm_params:
      model: ollama/gemma4:12b
      api_base: http://localhost:11434
      api_key: "ollama-local"
      max_tokens: 4096
      extra_body:
        num_ctx: 8192

  - model_name: local-coder
    litellm_params:
      model: ollama/gemma4:12b
      api_base: http://localhost:11434
      api_key: "ollama-local"
      max_tokens: 4096
      extra_body:
        num_ctx: 8192

router_settings:
  fallbacks:
    - {"big-pickle": ["local-coder"]}
  allowed_fails: 1

general_settings:
  master_key: "sk-12345678"
  completion_model: big-pickle
```

**Healthcheck:**

```bash
litellm --config ~/litellm/config.yaml --port 4000 &
curl -s http://localhost:4000/v1/models -H "Authorization: Bearer sk-12345678"
```

*Verify that all models are returned: big-pickle, claude-sonnet-4-5, claude-haiku-4-5, gpt-5.2, gpt-5.1-codex, deepseek-v4-flash-free, gemma4, local-coder.*

## Step 9 — Configure OpenCode

`~/.config/opencode/opencode.json`

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode/big-pickle",
  "small_model": "opencode/claude-haiku-4-5",
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
        "claude-sonnet-4-5": {
          "id": "claude-sonnet-4-5",
          "name": "Claude Sonnet 4.5 (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 3, "output": 15 },
          "limit": { "context": 200000, "output": 16384 }
        },
        "claude-haiku-4-5": {
          "id": "claude-haiku-4-5",
          "name": "Claude Haiku 4.5 (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 1, "output": 5 },
          "limit": { "context": 200000, "output": 16384 }
        },
        "gpt-5.2": {
          "id": "gpt-5.2",
          "name": "GPT 5.2 (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 1.75, "output": 14 },
          "limit": { "context": 272000, "output": 16384 }
        },
        "gpt-5.1-codex": {
          "id": "gpt-5.1-codex",
          "name": "GPT 5.1 Codex (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 1.07, "output": 8.5 },
          "limit": { "context": 272000, "output": 16384 }
        },
        "deepseek-v4-flash-free": {
          "id": "deepseek-v4-flash-free",
          "name": "DeepSeek V4 Flash Free (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 128000, "output": 16384 }
        },
        "gemma4": {
          "id": "gemma4",
          "name": "Gemma 4 12B Local (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 8192, "output": 4096 }
        },
        "local-coder": {
          "id": "local-coder",
          "name": "Local Coder (via LiteLLM)",
          "tool_call": true,
          "reasoning": false,
          "cost": { "input": 0, "output": 0 },
          "limit": { "context": 8192, "output": 4096 }
        }
      }
    }
  }
}
```

*Note: This configuration provides three providers:*
- *`opencode/` - Direct access to OpenCode Zen cloud models*
- *`litellm/` - All models via LiteLLM proxy (cloud + local)*
- *`ollama/` - Direct access to local Ollama models*

**Healthcheck:**
Execute a test prompt to verify connection.

# Daily Startup Script

`~/.aicode/aicode`

```bash
#!/bin/bash
export OPENCODE_API_KEY="YOUR_ZEN_KEY_HERE"

if ! pgrep -x "ollama" > /dev/null; then
  nohup ollama serve >/tmp/ollama.log 2>&1 &
  sleep 3
fi

if ! pgrep -f "litellm" > /dev/null; then
  nohup litellm --config ~/litellm/config.yaml --port 4000 >/tmp/litellm.log 2>&1 &
  sleep 3
fi

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
* LiteLLM responds and exposes all models (big-pickle, claude-sonnet-4-5, claude-haiku-4-5, gpt-5.2, gpt-5.1-codex, deepseek-v4-flash-free, gemma4, local-coder).
* OpenCode shows all three providers (opencode, litellm, ollama).
* Primary routing works.
* Fallback routing works on big-pickle -> local-coder.

Only then report:

> Installation completed successfully. You can now choose between OpenCode Zen models (big-pickle, claude-sonnet-4-5, etc.), LiteLLM proxy models, or local Ollama models directly in the OpenCode UI.