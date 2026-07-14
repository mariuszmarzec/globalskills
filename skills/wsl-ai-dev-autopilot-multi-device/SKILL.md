---
name: wsl-ai-dev-autopilot-multi-device
description: Fully automated WSL2 AI dev environment (OpenCode/Copilot compatible). Supports multi-device installation (PC + laptop). Includes hardware-aware model selection, strict healthchecks, self-healing loop and adaptive agent policy.
version: 1.3.0
platform: wsl2
tags: [autopilot, ai, wsl, ollama, litellm, opencode, copilot]
---

# WSL AI DEV AUTOPILOT

## Purpose

This skill guides an AI agent through the complete installation and validation of an AI development environment on WSL2.

Architecture:

OpenCode / Copilot / OpenAI-compatible Client
↓
LiteLLM
↓
Gemini (Free)
Groq (Free)
Ollama
↓
Local Models

---

# EXECUTION RULES

- Execute sequentially.
- Never skip a step.
- Never assume success.
- Every step MUST finish with a successful healthcheck.
- If a healthcheck fails, enter Self-Healing mode.
- Retry up to three times.
- If still failing, stop and explain the root cause.
- Never overwrite an existing working configuration without creating a backup.

---

# SUCCESS CRITERIA

The task is complete only if ALL of the following are true:

- WSL2 operational
- Required Ubuntu packages installed
- Node.js installed
- Python installed
- Ollama installed and responding
- LiteLLM installed and responding
- Local models installed
- Remote providers configured (if requested)
- OpenAI-compatible endpoint working
- Test prompt succeeds
- Fallback routing verified

---

# USER INTERACTION POLICY

Before installation, ask:

1. Which machine is being configured?

- Desktop
- Laptop

Do not continue until the user answers.

Then ask:

2. Should free remote providers (Gemini and Groq) be configured now?

Automatically detect everything else.

---

# HARDWARE PROFILES

## Desktop

CPU:
AMD Ryzen 9 5900X

RAM:
32 GB

GPU:
RTX 3070 8 GB

Recommended models:

- qwen3-coder:14b
- qwen3:14b

Optional:

- deepseek-coder 14b (if available)

---

## Laptop

CPU:
Intel i7-7700HQ

RAM:
16 GB

GPU:
GTX 1050 Ti 4 GB

Recommended models:

- qwen2.5-coder:7b
- qwen2.5:7b
- phi-3-mini (optional lightweight fallback)

Never install 14B models on this hardware unless the user explicitly requests it.

---

# AGENT DECISION POLICY

The AI agent is responsible for selecting the most appropriate model.

LiteLLM is responsible only for:

- routing
- retries
- fallbacks
- provider abstraction
- OpenAI-compatible API

Do not implement semantic task routing inside LiteLLM.

---

# MODEL SELECTION POLICY

Prefer:

1. Remote free models
2. Best local coding model
3. Local fallback

Desktop:

- qwen3-coder:14b
- qwen3:14b

Laptop:

- qwen2.5-coder:7b
- qwen2.5:7b

Never choose a model larger than the hardware can comfortably execute.

---

# DETECTION POLICY

Automatically detect:

- CPU
- RAM
- GPU
- Disk space
- WSL version
- Ubuntu version
- Existing Node installation
- Existing Python installation
- Existing Ollama installation
- Existing LiteLLM installation

Only ask the user when automatic detection is impossible.

---

# IDEMPOTENCY

The skill must be safely re-runnable.

Never reinstall software that is already healthy.

Verify first.

Repair only when necessary.

Always back up configuration files before modifying them.

---

# SELF-HEALING LOOP

Whenever a step fails:

1. Diagnose the error.
2. Attempt automatic recovery.
3. Repeat the failed step.
4. Execute the healthcheck again.
5. Continue only if HEALTHCHECK = OK.

Recovery actions may include:

- reinstall package
- restart service
- free occupied ports
- re-download models
- regenerate configuration
- restore missing environment variables

Maximum retries: 3

---

# INSTALLATION

## 1. Update system

sudo apt update && sudo apt upgrade -y

sudo apt install -y \
curl \
git \
jq \
unzip \
build-essential \
python3-pip

Healthcheck:

curl --version
git --version
python3 --version

---

## 2. Install Node.js

curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash

source ~/.bashrc

nvm install --lts

nvm use --lts

Healthcheck:

node -v
npm -v

---

## 3. Install OpenCode

Follow the current official OpenCode installation instructions.

Healthcheck:

opencode --help

---

## 4. Install Ollama

curl -fsSL https://ollama.com/install.sh | sh

Healthcheck:

ollama --version

---

## 5. Start Ollama

ollama serve

Healthcheck:

curl http://localhost:11434/api/tags

---

## 6. Install Local Models

Desktop:

ollama pull qwen3-coder:14b
ollama pull qwen3:14b

Laptop:

ollama pull qwen2.5-coder:7b
ollama pull qwen2.5:7b

Healthcheck:

ollama list

---

## 7. Install LiteLLM

pip3 install litellm

Healthcheck:

litellm --help

---

## 8. Configure LiteLLM

Create:

~/litellm/config.yaml

Configure:

- Gemini as primary
- Groq as secondary
- Local coding model as fallback
- Local reasoning model as final fallback

Healthcheck:

litellm --config ~/litellm/config.yaml --port 4000

curl http://localhost:4000/v1/models

---

## 9. Configure Client

Use:

Base URL:

http://localhost:4000

API Key:

dummy

Model:

primary

Healthcheck:

Execute a test prompt.

---

# DAILY STARTUP

## Option A: Unified Script (Recommended)

Create `~/.aicode/aicode`:

```bash
#!/bin/bash
# aicode - Start AI dev environment and launch OpenCode

# Ensure Ollama is running
if ! pgrep -x "ollama" > /dev/null; then
    nohup ollama serve > /tmp/ollama.log 2>&1 &
    sleep 3
fi

# Ensure LiteLLM is running
if ! pgrep -f "litellm" > /dev/null; then
    nohup litellm --config ~/litellm/config.yaml --port 4000 > /tmp/litellm.log 2>&1 &
    sleep 3
fi

# Launch OpenCode
exec opencode "$@"
```

Make executable:

```bash
chmod +x ~/.aicode/aicode
```

Add alias to `~/.zshrc` or `~/.bashrc`:

```bash
alias aicode='~/.aicode/aicode'
```

Usage:

```bash
aicode          # starts services (if needed) + launches opencode
aicode .        # opens current directory
aicode [args]   # passes args to opencode
```

## Option B: Manual Steps

1. Start Ollama

2. Start LiteLLM

3. Launch OpenCode / Copilot

---

# FINAL VALIDATION

Verify:

- Ollama responds
- LiteLLM responds
- Local models respond
- Remote providers authenticate (if enabled)
- Routing works
- Fallback works
- Test prompt succeeds

Only then report:

Installation completed successfully.
