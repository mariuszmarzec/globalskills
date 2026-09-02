---
name: openclaw-knowledge

description: OpenClaw general knowledge + current known-good setup. Use before making changes to avoid incorrect assumptions about OpenClaw, authentication, Gateway lifecycle, systemd, plugins, and state separation.

license: MIT
---

# OpenClaw Knowledge

## PART 1 — OPENCLAW GENERAL KNOWLEDGE
======================================

### What OpenClaw is

OpenClaw is an **AI Gateway** that enables AI model providers to work with **agents** and **channels** for AI interactions.

#### Core components

**Gateway architecture**
- The **Gateway** is the central process that handles all incoming requests
- Manages **agents** (coordination entities), **channels** (communication endpoints), **model providers** (backend model services), and **plugins** (extensions)
- Provides HTTP/WebSocket control plane and HTTP model serving

**Agents**
- **Default agent:** `main` - the built-in agent for generic AI requests
- Each agent can have **agent-specific state**, **model selection**, and **local configuration**
- **Agent identity** determines authentication and model resolution

**Model providers**
- Backend services that actually execute AI models (OpenAI, Anthropic, Groq, etc.)
- **Provider IDs** like `openai`, `anthropic`, `groq`
- **Model IDs** like `gpt-4`, `claude-3-5-sonnet`, `llama-3.3-70b-versatile`
- Referenced as `provider/model` (e.g., `litellm/groq-llama-70b`)

**Channels**
- Communication endpoints for specific purposes
- `openai-completions`, `claude-messages`, etc.
- Route requests between Gateway and providers

**Plugins**
- Extensions that add functionality to OpenClaw
- **Bundled** (built-in) vs **installed** (user-added)
- **Plugin capabilities** require explicit consent
- **Verification** required before use

**Workspace**
- Root directory for all OpenClaw state and configuration
- Typically: `/mnt/f/ubuntu-workspace/.openclaw`
- Contains: `state/`, `agents/`, `manul/`, etc.

**State**
- **Global/shared state:** available to all agents
- **Agent-local state:** specific to individual agents
- **Persistent state:** survives across restarts
- **Runtime state:** temporary during execution
- **Sessions:** tracked interactions between agents and models

**Authentication**
- **Gateway authentication:** API key for accessing the Gateway itself
- **Model provider authentication:** API keys for backend models
- **Auth profiles:** named authentication configurations
- **Shared/global auth state:** accessible to all agents
- **Agent-local auth state:** specific to individual agents

## PART 2 — KNOWN-GOOD USER SETUP
===============================

### Known-good WSL2 setup

**Architecture:**
```
Windows
↓
WSL2 Ubuntu
↓
/mnt/f/ubuntu-workspace/
↓
OpenClaw Gateway
↓
127.0.0.1:18789
↓
main agent
↓
LiteLLM 127.0.0.1:4000
↓
litellm/groq-llama-70b
↓
Groq
```

**Environment details:**
- **OpenClaw version:** `2026.8.2`
- **Gateway port:** `18789`
- **Gateway bind:** loopback / `127.0.0.1`
- **state root:** `/mnt/f/ubuntu-workspace/.openclaw/state`
- **Manul:** `/mnt/f/ubuntu-workspace/.openclaw/manul`
- **OPENCLAW_STATE_DIR:** `/mnt/f/ubuntu-workspace/.openclaw/state`
- **OPENCLAW_MANUL_DIR:** `/mnt/f/ubuntu-workspace/.openclaw/manul`
- **OPENCLAW_PATH:** `/mnt/f/ubuntu-workspace/.openclaw`

**OpenClaw model configuration:**
- **Provider:** `litellm`
- **Base URL:** `http://127.0.0.1:4000/v1`
- **API:** `openai-completions`
- **Default model:** `litellm/groq-llama-70b`

**LiteLLM mapping:**
```
litellm/groq-llama-70b
→ groq/llama-3.3-70b-versatile
```

**IMPORTANT:** The Groq API key belongs to LiteLLM and must NOT be copied into OpenClaw. OpenClaw uses the local LiteLLM API key.

## PART 3 — KNOWN-GOOD AUTHENTICATION STATE
========================================

**Working auth state:**
- **agent:** `main`
- **provider:** `litellm`
- **profile:** `litellm:manual`
- **LiteLLM key:** local proxy key

**Verification command:**
```bash
openclaw gateway call openclaw.setup.verify --json
```

**Expected output:**
```json
{"ok":true,"modelRef":"litellm/groq-llama-70b"}
```

**IMPORTANT:** Do NOT document a fictional `openclaw models auth sync` command. It does not exist in the user's OpenClaw `2026.8.2` CLI.

## PART 4 — KNOWN-GOOD GATEWAY LIFECYCLE
=====================================

**Startup methods:**
- Manual: `npm exec openclaw gateway --force --allow-unconfigured --port 18789`
- Background: `aicode` script (idempotent)

**Do NOT use:**
- `openclaw gateway run --dev`
- `--dev` flag (unless explicitly requested for development)
- `openclaw gateway restart`
- `pkill -f "openclaw gateway"`

**Correct background startup behavior:**
1. Check if `127.0.0.1:18789` is already listening
2. If running:
   - Leave it alone
   - Do NOT kill it
   - Do NOT restart it
3. If not running:
   - Start: `npm exec openclaw gateway --force --allow-unconfigured --port 18789`
4. Wait for readiness
5. Verify Gateway availability

**No systemd management in this setup.** The user's current preference is manual/foreground startup, not service-managed Gateway.

## PART 5 — MANUL
============

Manul is a **separate component** in this environment:

- **Intentional management:** Handled by the existing `aicode` workflow
- **DO NOT remove Manul** from the startup workflow
- **DO NOT convert Manul** into an OpenClaw agent
- **DO NOT modify Manul** while troubleshooting OpenClaw unless the task explicitly concerns Manul

**Current OpenClaw agent list:** Contains `main`; Manul is **not** an OpenClaw agent

## PART 6 — AICODE STARTUP SCRIPT
===============================

**Purpose:** Start/ensure local AI development stack

**Managed components:**
- Ollama
- PostgreSQL
- LiteLLM
- OpenClaw Gateway
- Manul
- OpenCode

**OpenClaw behavior for `aicode`:**
- May start OpenClaw in background (idempotent)
- Correct behavior:
  1. Check port 18789
  2. If running: leave alone, do NOT kill/restart
  3. If not running: start known-good Gateway command
  4. Wait for readiness
  5. Verify Gateway availability

**Never use:**
- Unconditional `pkill -f "openclaw gateway"`
- `openclaw gateway restart` as normal startup

## PART 7 — SAFE TROUBLESHOOTING PLAYBOOK
=====================================

### Problem: Gateway unavailable
→ Check process/port
→ Check `openclaw gateway status`
→ Inspect logs (`/tmp/openclaw-gateway.log`)
→ If necessary: start known-good Gateway command
→ Verify connectivity (`curl http://127.0.0.1:18789`)
→ Verify setup (`openclaw gateway call openclaw.setup.verify --json`)
→ Test real model request

### Problem: setup.verify says model/auth missing
→ Inspect current model configuration
→ Inspect auth state/profile
→ Determine: Gateway auth issue vs model-provider auth issue
→ Do NOT blindly run onboard
→ Do NOT modify unrelated configuration
→ Do NOT repair plugins

### Problem: model request fails
→ Verify LiteLLM is alive on `127.0.0.1:4000`
→ Verify model name
→ Verify OpenClaw provider configuration
→ Verify auth profile
→ Inspect actual error
→ Make smallest required change

### Problem: plugin warning
→ Determine if requested task uses that plugin
→ If not, leave it alone
→ Do NOT install/accept capabilities just for diagnostics

### Problem: systemd failure
→ Do NOT automatically repair systemd
→ Determine if user's intended lifecycle uses systemd
→ In this setup, it does NOT

## PART 8 — CRITICAL AGENT RULES
===========================

### Rules for AI agents

**High priority:**
- Verify before changing
- Treat agent summaries as hypotheses, not ground truth
- Never invent CLI commands
- Check `--help` or source/docs when uncertain
- Prefer smallest possible change
- Do not modify unrelated components
- Do not "repair" plugins unless required
- Do not introduce systemd when user does not use systemd
- Do not restart working Gateway unnecessarily
- Do not kill processes just for startup script determinism
- Preserve known-good configurations
- After successful end-to-end test, STOP
- Never turn narrow troubleshooting into full environment migration

**Authentication rules:**
- Never assume authentication problem is "fixable" by running onboarding
- Distinguish between Gateway auth and model-provider auth
- Do NOT modify unrelated configuration to "fix" auth
- Inspect auth state safely before making changes

## PART 9 — VERSION AWARENESS
===========================

**Important distinction:**
- `OpenClaw general/current documentation`
- `User's verified OpenClaw 2026.8.2 behavior`

**Command usage rule:**
Do NOT silently assume current OpenClaw documentation matches installed `2026.8.2` CLI.

When command/config differs by version:
- State the version
- Verify against installed version
- Prefer observed/verified behavior for this user's environment

**Use official OpenClaw documentation as primary external reference** where appropriate.

## PART 10 — VALIDATION
=====================

**After creating/updating skill:**
1. Inspect final skill for contradictions
2. Ensure it does not recommend systemd usage for this setup
3. Ensure it does not recommend removing Manul
4. Ensure it does not recommend `--dev` startup
5. Ensure it does not recommend blindly `pkill` OpenClaw
6. Ensure no nonexistent CLI commands
7. Ensure known-good model path is exactly: `litellm/groq-llama-70b`
8. Ensure LiteLLM remains: `127.0.0.1:4000`
9. Ensure Gateway remains: `127.0.0.1:18789`
10. Ensure state remains under: `/mnt/f/ubuntu-workspace/.openclaw/state`
11. Ensure skill clearly says `aicode` may start OpenClaw in background
12. Ensure skill says already-running OpenClaw must NOT be killed/restarted
13. Run any repository-standard validation/linting for skill

**If an existing OpenClaw skill was found:**
- UPDATE it with this content
- Report: "OpenClaw skill FOUND and UPDATED"

**If no OpenClaw skill exists:**
- CREATE one in appropriate directory
- Report: "OpenClaw skill NOT FOUND - CREATED new skill"