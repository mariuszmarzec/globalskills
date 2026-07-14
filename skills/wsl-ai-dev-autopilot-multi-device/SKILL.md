# WSL AI Dev Autopilot Skill

```yaml
name: wsl-ai-dev-autopilot-multi-device
description: Fully automated WSL2 AI dev environment (OpenCode compatible). Supports multi-device installation (PC + laptop). Includes hardware-aware model selection, strict healthchecks, self-healing loop and adaptive Zen-to-Local fallback routing.
version: 1.4.0
platform: wsl2
tags: [autopilot, ai, wsl, ollama, litellm, opencode, copilot]
```

# Purpose

This skill guides an AI agent through the complete installation and validation of an AI development environment on WSL2.

## Architecture

```text
OpenCode Client
        │
        ▼
LiteLLM (Router & Fallback Manager)
        │
        ├── OpenCode Zen (Primary - Big Pickle)
        │
        └── Ollama (Fallback - Qwen Local)
                    │
                    ▼
               Local Models
```

# Execution Rules

- Execute sequentially.
- Never skip a step.
- Never assume success.
- Every step MUST finish with a successful healthcheck.
- If a healthcheck fails:
  - Enter Self-Healing mode.
  - Retry up to three times.
  - If still failing, stop and explain the root cause.
- Never overwrite an existing working configuration without creating a backup.

# Success Criteria

- WSL2 operational
- Ubuntu packages installed
- Node.js installed
- Python installed
- Ollama installed and responding
- LiteLLM installed and responding
- Local models installed
- OpenCode configured
- Test prompt succeeds
- Fallback routing verified

# User Interaction Policy

Before installation ask:

1. Which machine is being configured? (Desktop or Laptop)

Do not continue until answered. Detect everything else automatically.

# Communication Protocol for OpenCode

Every response must follow:

```text
MY THOUGHT PROCESS:
Explain current step, previous result and next action.

INTERACTION:
Question for the user or N/A.

COMMAND TO EXECUTE:
Exact bash commands or WAITING.
```

# Hardware Profiles

## Desktop

- CPU: AMD Ryzen 9 5900X
- RAM: 32 GB
- GPU: RTX 3070 8 GB
- Recommended:
  - qwen3-coder:14b
  - qwen3:14b

## Laptop

- CPU: Intel i7-7700HQ
- RAM: 16 GB
- GPU: GTX 1050 Ti 4 GB
- Recommended:
  - qwen2.5-coder:7b
  - qwen2.5:7b

> Never install 14B models on the laptop unless explicitly requested.

# Policies

## Agent Decision Policy

- Agent selects the best model.
- LiteLLM handles routing, retries, fallbacks and OpenAI-compatible API abstraction.

## Model Selection Policy

1. OpenCode Zen
2. Best local coding model

Desktop fallback:
- qwen3-coder:14b

Laptop fallback:
- qwen2.5-coder:7b

## Detection Policy

Automatically detect:

- CPU
- RAM
- GPU
- Disk space
- WSL version
- Ubuntu version
- Node
- Python
- Ollama
- LiteLLM

Ask the user only if automatic detection is impossible.

## Idempotency & Self-Healing

- Safe to rerun.
- Never reinstall healthy software.
- Verify first.
- Repair only if necessary.
- Retry failed steps up to 3 times.

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
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
source ~/.bashrc
nvm install --lts
nvm use --lts
```

Healthcheck:

```bash
node -v
npm -v
```

## Step 3 — Install OpenCode

Follow the current official installation instructions.

Healthcheck:

```bash
opencode --help
```

## Step 4 — Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Healthcheck:

```bash
ollama --version
```

## Step 5 — Start Ollama

```bash
ollama serve
```

Healthcheck:

```bash
curl http://localhost:11434/api/tags
```

## Step 6 — Install Local Models

Desktop

```bash
ollama pull qwen3-coder:14b
```

Laptop

```bash
ollama pull qwen2.5-coder:7b
```

Healthcheck

```bash
ollama list
```

## Step 7 — Install LiteLLM

```bash
pip3 install litellm
```

Healthcheck

```bash
litellm --help
```

## Step 8 — Configure LiteLLM

Create:

```text
~/litellm/config.yaml
```

```yaml
model_list:
  - model_name: default-model
    litellm_params:
      model: opencode/big-pickle
      api_base: https://api.opencode.com/v1
      api_key: os.environ/OPENCODE_API_KEY

  - model_name: local-fallback
    litellm_params:
      model: ollama/qwen2.5-coder:7b
      api_base: http://localhost:11434

router_settings:
  fallbacks:
    - {"default-model": ["local-fallback"]}
  allowed_fails: 1
  context_window_fallbacks:
    - {"default-model": ["local-fallback"]}
```

Healthcheck

```bash
litellm --config ~/litellm/config.yaml --port 4000 &
curl http://localhost:4000/v1/models
```

## Step 9 — Configure OpenCode

`~/.config/opencode/opencode.json`

```json
{
  "model": "default-model",
  "api_base": "http://localhost:4000",
  "api_key": "dummy-key"
}
```

Healthcheck:

Execute a test prompt.

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
chmod +x ~/.aicode/aicode
alias aicode='~/.aicode/aicode'
```

# Final Validation

Verify:

- Ollama responds
- LiteLLM responds
- Primary routing works
- Fallback routing works

Only then report:

> Installation completed successfully.
