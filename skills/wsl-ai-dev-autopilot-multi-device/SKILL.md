---
name: wsl-ai-dev-autopilot-multi-device
description: Simple WSL2 AI development environment using one LiteLLM model group (free-cloud) backed by FreeLLMAPI, with OpenCode, OpenClaw, Manul, and optional Caracal RAG MCP integration. Use when installing or repairing this single-model setup.
---

# WSL AI Dev Autopilot Skill


# Purpose

Install and validate a WSL2 AI development environment using one chat-model route:

`OpenCode / OpenClaw / Manul → LiteLLM → FreeLLMAPI → openai/auto`

LiteLLM exposes **exactly one model group: `free-cloud`**. Every client and every Globalskills agent requests `litellm/free-cloud`. Do not create aliases, per-role model groups, direct provider routes, fallback chains, or local chat-model routes.

FreeLLMAPI may manage its upstream provider pool internally. From the perspective of LiteLLM, OpenCode, OpenClaw, and Manul, the only model is `free-cloud`.

Caracal RAG is a separate service. Its embeddings endpoint is configured in `~/.caracal/config/sources.yaml`; do not add an embedding model to LiteLLM's chat `model_list`. Keep its authenticated MCP listener loopback-only and pass its bearer token through the launcher environment, never through repository files.

## Architecture

```text
OpenCode ─┐
OpenClaw ─┼──> LiteLLM :4000 ──> FreeLLMAPI :3001/v1 (openai/auto)
Manul ────┘        exposes only "free-cloud"

OpenCode ──> authenticated Caracal MCP :3500 ──> Chroma
                       (embeddings configured separately)
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

- WSL2 and required Ubuntu packages are operational.
- Node.js, Python, and OpenCode are installed.
- FreeLLMAPI responds on its configured loopback endpoint.
- LiteLLM exposes exactly one model group: `free-cloud`.
- A chat completion succeeds through LiteLLM using `model: free-cloud`.
- OpenCode uses `litellm/free-cloud` for both its main and small model.
- OpenClaw and Manul use only `litellm/free-cloud`.
- No other LiteLLM model groups, aliases, direct providers, or fallback routes are configured.
- Caracal RAG is installed under `~/.caracal` with its own Python virtual environment; source remains at `~/.caracal-rag`.
- Caracal credentials, embedding endpoint, Chroma settings, and `caracal-rag check` are valid.
- The configured knowledge sources `fiteo-docs` and `quickmvi-readme` are indexed successfully.
- `aicode` validates LiteLLM and Caracal; `opencode mcp list` confirms Caracal MCP connectivity.


# User Interaction Policy

- Detect the current machine and installed components automatically.
- Do not ask whether the machine is Desktop or Laptop; model configuration is identical.
- Ask only for information that cannot be discovered safely, such as a missing FreeLLMAPI key or unknown endpoint.
- Never request secrets in plain text chat when a local hidden prompt or secure environment file can be used.
- Inspect existing configuration before changing it. Back up working files and preserve unrelated MCP servers, permissions, and runtime settings.

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




# Policies

## Single-model policy

- The only LiteLLM model group is `free-cloud`, backed by FreeLLMAPI `openai/auto`.
- OpenCode, OpenClaw, Manul, and every generated role agent use `litellm/free-cloud`.
- Do not add aliases such as `big-pickle` or `deepseek-v4-flash-free`.
- Do not add direct Groq, Cerebras, Gemini, Mistral, OpenRouter, Ollama, or OpenCode Zen chat routes.
- Do not configure `router_settings.fallbacks` or `completion_model`.
- LiteLLM retries may retry the same `free-cloud` model group but must never fail over to another group.
- LiteLLM needs only `FREELLMAPI_API_KEY` and `LITELLM_MASTER_KEY`; provider credentials stay in FreeLLMAPI.

## Detection Policy

Automatically detect CPU, RAM, disk space, WSL/Ubuntu, Node.js, Python, OpenCode, FreeLLMAPI, LiteLLM, PostgreSQL, and Caracal. Hardware detection is informational; it must not select or install local model weights.

## Idempotency & Safety

- Inspect first; repair only what is missing or invalid.
- Execute sequentially and verify every step.
- If a healthcheck still fails after bounded retries, stop and report the cause.
- Never overwrite a working configuration without a backup.
- Never restart a service while it handles active work.
- Do not print secrets or place them in command-line arguments, logs, or repository files.

## Multi-device setup

Use the same LiteLLM and OpenCode model configuration on every device. Each device must reach its configured FreeLLMAPI endpoint. Do not substitute model names or providers based on hardware.

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


## Step 4 — Install LiteLLM

```bash
pip3 install litellm
```

**Healthcheck**

```bash
litellm --help
```


## Step 5 — Configure LiteLLM

Create `~/litellm/free-cloud`:

```bash
LITELLM_MASTER_KEY=<generate-a-long-random-key>
FREELLMAPI_API_KEY=<your-FreeLLMAPI-unified-key>
```

Protect it:

```bash
chmod 600 ~/litellm/free-cloud
```

Create `~/litellm/free-cloud`. This is the complete configuration; do not append other models or aliases:

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

Do not add `router_settings`, fallbacks, `completion_model`, or `default_embedding_models`. Caracal embeddings are configured separately, not in this chat-model list.

Load the environment into the LiteLLM service process. Reload the existing service using its normal service manager; do not start a second proxy process.

**Healthchecks**

```bash
set -a
source ~/litellm/free-cloud
set +a

curl -fsS http://127.0.0.1:3001/v1/models \
  -H "Authorization: Bearer $FREELLMAPI_API_KEY"

curl -fsS http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

The LiteLLM response must contain exactly one model ID: `free-cloud`. Then send one chat-completion request with `model: free-cloud`. If it fails, inspect FreeLLMAPI and LiteLLM logs; do not add fallback providers.

### Multi-device

Repeat the same setup on each device. Use `127.0.0.1:3001` only when FreeLLMAPI runs on that same device.

## Step 6 — Install globalskills (agents + skills)

The environment ships with shared skills (`~/.globalskills/skills`) and OpenCode agents (`~/.globalskills/agents`). OpenCode only reads agents from `~/.config/opencode/agents/`, so they must be symlinked — `install.sh` does this automatically. This must run on **every** machine (Desktop and Laptop) before configuring OpenCode.

```bash
# Clone or update the globalskills repo
if [ -d ~/.globalskills ]; then
  git -C ~/.globalskills pull --ff-only
else
  git clone git@github.com:mariuszmarzec/globalskills.git ~/.globalskills \
    || git clone https://github.com/mariuszmarzec/globalskills.git ~/.globalskills
fi

# Install native skill and agent copies for OpenCode and GitHub Copilot
bash ~/.globalskills/install.sh
```

**Healthcheck:**

```bash
test -e ~/.config/opencode/agents/orchestrator.md && echo "agents OK"
test -e ~/.agents/skills/wsl-ai-dev-autopilot-multi-device/SKILL.md && echo "skills OK"
```

*If SSH fails on a fresh machine (no key deployed), fall back to the HTTPS clone URL shown above.*


## Step 7 — Install and configure Caracal RAG

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
```

Configure Caracal interactively so credentials are entered into hidden prompts, not shell history or process arguments:

```bash
"$HOME/.caracal/bin/caracal-rag" setup
```

During setup, select an embedding family that is actually enabled in the FreeLLMAPI deployment under **Models → Embeddings**; do not guess a model or use `auto`. The key and access token are stored in `~/.caracal/config/secrets.yaml` with restrictive permissions. Confirm `~/.caracal/config/sources.yaml` points to the intended FreeLLMAPI base URL, Chroma host/port/collection, and includes both knowledge sources:

- `fiteo-docs` — API Markdown documents from `mariuszmarzec/fiteo/docs/api/` on `master`.
- `quickmvi-readme` — `https://raw.githubusercontent.com/mariuszmarzec/QuickMVI/develop/README.md`, covering QuickMVI library usage at README level.

The installer preserves an existing `sources.yaml`; updating `config/sources.example.yaml` does not merge new sources into an already-installed config. If `quickmvi-readme` is missing, add this item under the existing `sources:` list (do not create a duplicate `sources:` key):

```yaml
  - name: quickmvi-readme
    type: markdown
    url: https://raw.githubusercontent.com/mariuszmarzec/QuickMVI/develop/README.md
```

Defaults in the template are FreeLLMAPI at `http://127.0.0.1:3001/v1`, Chroma at `127.0.0.1:3400`, and MCP at `127.0.0.1:3500/mcp`; change them only when the deployment really uses different endpoints. The Caracal embedding endpoint is independent from LiteLLM's chat-model routing.

```bash
"$HOME/.caracal/bin/caracal-rag" check
"$HOME/.caracal/bin/caracal-rag" index --source fiteo-docs
"$HOME/.caracal/bin/caracal-rag" index --source quickmvi-readme
"$HOME/.caracal/bin/caracal-rag" check
```

**Healthcheck:** both `check` calls succeed, indexing completes, and `~/.caracal/config/secrets.yaml` has mode `0600`. Do not start MCP or claim setup is complete if credentials, embedding-model validation, or Chroma connectivity fails; fix the reported dependency and rerun the check.

The authenticated MCP server is launched by `aicode` after LiteLLM. Keep `mcp.host: 127.0.0.1`; never expose the token-authenticated listener on a public interface. The launcher tracks only its own PID in `~/.caracal/run/mcp.pid`, logs to `/tmp/caracal-mcp.log`, and does not kill an unknown process that happens to use the configured port.


## Step 8 — Configure OpenCode

Use `litellm/free-cloud` for both main and small requests. Merge the following settings into the existing `~/.config/opencode/opencode.json`; do not replace existing MCP servers, permissions, or unrelated settings.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "litellm/free-cloud",
  "small_model": "litellm/free-cloud",
  "default_agent": "orchestrator",
  "skills": {
    "paths": ["~/.agents/skills"]
  },
  "providers": {
    "litellm": {
      "name": "LiteLLM Proxy",
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "http://127.0.0.1:4000/v1",
        "apiKey": "{env:LITELLM_MASTER_KEY}"
      },
      "models": {
        "free-cloud": {
          "modelID": "free-cloud",
          "name": "FreeLLMAPI auto (via LiteLLM)",
          "capabilities": {
            "tools": true,
            "input": ["text"],
            "output": ["text"]
          }
        }
      }
    }
  }
}
```

Keep only the `free-cloud` entry under the LiteLLM provider. Remove stale model aliases and direct chat providers from this model configuration. Preserve existing Caracal, Fiteo, and Todo MCP servers and permissions.

**Healthcheck:** run a short OpenCode task that invokes a tool and verify it completes through `litellm/free-cloud`. If the FreeLLMAPI auto pool cannot handle tool calls, fix that pool; do not add another LiteLLM model.


## Step 9 — Install & Configure OpenClaw

Install OpenClaw:

```bash
npm install -g openclaw@latest
openclaw --version
```

Configure one LiteLLM provider and one model in `~/.openclaw/openclaw.json` (JSON5). Insert the actual `LITELLM_MASTER_KEY` from `~/litellm/free-cloud`; protect the config file and never commit it.

```json5
{
  models: {
    providers: {
      litellm: {
        baseUrl: "http://127.0.0.1:4000/v1",
        apiKey: "<LITELLM_MASTER_KEY>",
        api: "openai-completions",
        timeoutSeconds: 300,
        models: [
          {
            id: "free-cloud",
            name: "FreeLLMAPI auto (via LiteLLM)",
            reasoning: false,
            input: ["text"],
            contextWindow: 128000,
            maxTokens: 8192
          }
        ],
      },
    },
  },
  agents: {
    defaults: {
      model: { primary: "litellm/free-cloud" },
    },
  },
}
```

Keep advertised context/output limits at or below actual FreeLLMAPI auto-pool capabilities. Do not add other model IDs or fallback providers.

Configure local Gateway mode and validate:

```bash
openclaw config set gateway.mode local
openclaw config set gateway.auth.mode token
openclaw config validate
```

**Healthchecks**

```bash
openclaw gateway status
openclaw models list
openclaw agent --agent main --session-key healthcheck \
  -m "Reply with exactly: LiteLLM connection OK" \
  --model litellm/free-cloud
```

The model list must show only `litellm/free-cloud` from this provider, and the test turn must succeed.

# Daily Startup Script

The maintained launcher is `~/.globalskills/aicode/aicode`; `install.sh` links it to `~/.aicode/aicode`. Avoid maintaining a divergent copied launcher. If an existing file occupies that path, the installer preserves it in a timestamped backup before linking the maintained version.

On each startup, `aicode` starts/validates LiteLLM first, then validates Caracal and starts its authenticated HTTP MCP on loopback only when `caracal-rag check` passes. The operator-owned OpenCode JSON/JSONC config must already contain the static V2 entry `mcp.servers["caracal-rag"]` with the hardcoded loopback URL `http://127.0.0.1:3500/mcp` and the `{env:CARACAL_ACCESS_TOKEN}` bearer-token placeholder. Keep this Caracal entry intact during updates and migrations; do not replace its URL with `{env:CARACAL_MCP_URL}`. `aicode` never generates, migrates, backs up, or rewrites that config; it only verifies that the configured Caracal server is connected. It points OpenClaw's ACPX `opencode` harness at `~/.globalskills/aicode/opencode-acp-caracal.sh` and sets `plugins.entries.acpx.config.probeAgent: "opencode"` so ACPX startup healthchecks validate this exact harness. Before each ACP session, the wrapper resolves the current local endpoint/token, exports `CARACAL_MCP_URL`, `CARACAL_ACCESS_TOKEN` and `OPENCODE_CONFIG`, and requires `opencode mcp list` to report Caracal connected before it executes `opencode acp`. Manul's direct OpenCode adapter performs the same provider refresh for task processes started by a long-running daemon. This keeps credentials on the process that actually owns Caracal tools and avoids duplicating Caracal as a native OpenClaw MCP server. The ACPX plugin must already be enabled. If Caracal is unavailable, the static config is missing, or the live probe fails, startup stops instead of starting a partially configured agent. Todo Desktop MCP remains optional: a missing/unconnected Todo server never blocks a session. The launcher reuses a healthy Caracal process only when the PID file and command line prove it owns that process; it will not kill an unrelated process or send credentials to an unverified endpoint. See `/tmp/caracal-mcp.log` for startup errors.

```bash
bash ~/.globalskills/install.sh
grep -qF "alias aicode='~/.aicode/aicode'" ~/.bashrc || echo "alias aicode='~/.aicode/aicode'" >> ~/.bashrc
source ~/.bashrc
aicode
```


# FreeLLMAPI integration

FreeLLMAPI is the only upstream used by LiteLLM for chat completions.

1. Run FreeLLMAPI locally and bind it to loopback (`127.0.0.1:3001`).
2. Configure the upstream provider pool and unified API key inside the FreeLLMAPI dashboard.
3. Store the unified key only in `~/litellm/free-cloud` as `FREELLMAPI_API_KEY`.
4. Configure exactly one LiteLLM model group: `free-cloud`, with `model: openai/auto`.
5. Configure OpenCode, OpenClaw, and Manul to request `litellm/free-cloud`.

The FreeLLMAPI catalogue may contain multiple upstream models; this does not mean LiteLLM should expose multiple model groups. Keep LiteLLM's `model_list` limited to `free-cloud`.


# Final Validation

Verify:

- FreeLLMAPI responds at its loopback `/v1/models` endpoint.
- LiteLLM responds on port 4000 and `/v1/models` contains exactly one model group: `free-cloud`.
- A chat completion succeeds through LiteLLM with `model: free-cloud`.
- OpenCode uses `litellm/free-cloud` for main and small model.
- Every generated Globalskills OpenCode agent uses `litellm/free-cloud`.
- OpenClaw's default model is `litellm/free-cloud` and a test turn succeeds.
- Manul role execution uses the same single model route; no role may request an old alias.
- No fallback chain, direct LiteLLM provider, local model group, or OpenCode Zen model is required.
- PostgreSQL/LiteLLM database health is verified when `database_url` is configured.
- Caracal `check` and source indexing succeed; authenticated MCP responds on loopback.
- `opencode mcp list` reports Caracal connected when launched through `aicode`.
- OpenClaw ACPX points the `opencode` harness at `~/.globalskills/aicode/opencode-acp-caracal.sh`.
- The ACP wrapper verifies Caracal with the current secret, then starts `opencode acp`.
- Manul's OpenCode adapter injects Caracal into its task-local config and requires the MCP to be connected.

Only then report:

> Installation completed successfully. LiteLLM exposes only `free-cloud`, backed by FreeLLMAPI `openai/auto`. OpenCode, OpenClaw, and every Globalskills agent use `litellm/free-cloud`. Caracal RAG is configured separately for embeddings and MCP access.