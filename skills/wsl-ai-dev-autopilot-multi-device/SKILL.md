---
name: wsl-ai-dev-autopilot-multi-device
description: Set up WSL2 AI development with one FreeLLMAPI-backed LiteLLM chat group (free-cloud), a separate local Ollama embedding alias for Caracal RAG, and a shared Zsh environment for OpenCode and Manul.
---

# WSL AI Dev Autopilot Skill


# Purpose

Install and validate a WSL2 AI development environment using one chat-completion
route:

`OpenCode / OpenClaw → LiteLLM → FreeLLMAPI → openai/auto`

Manul is an orchestrator, not a separate model client; it relies on the selected
runtime's existing configuration. Its OpenCode adapter does not override the
operator's model or provider selection.

LiteLLM exposes exactly one chat model group named `free-cloud`. That is the
model name sent to LiteLLM; each client has its own selector namespace:

- OpenCode: provider key `litellm`, model-catalog key `freeLLMAPI`, selector
  `litellm/freeLLMAPI`, upstream `modelID: "free-cloud"`.
- OpenClaw: provider model ID `free-cloud`, selector
  `litellm/free-cloud`.
- Manul does not select a model or pass `--model`; when using OpenCode it
  relies on the operator's OpenCode config and selected agent.

Generated Globalskills OpenCode role definitions use
`litellm/freeLLMAPI`. Do not create chat aliases, per-role LiteLLM model
groups, direct chat provider routes or fallback chains.

Caracal RAG uses a separate, embedding-only alias in the same LiteLLM service:
`multilingual-e5-base → Ollama → qllama/multilingual-e5-base`. This alias is
not another chat group and must not be selected by OpenCode, OpenClaw, Manul or
any chat agent. Do not remove it when simplifying the chat model list.

Caracal's authenticated MCP listener remains loopback-only. Pass its bearer
token only to the Caracal process that needs it, never through repository files.

## Architecture

```text
OpenCode ──> LiteLLM :4000 (selector: "litellm/freeLLMAPI") ──┐
OpenClaw ──> LiteLLM :4000 (selector: "litellm/free-cloud") ──┴─>
                 one chat group: "free-cloud"
                 FreeLLMAPI :3001/v1 (openai/auto)

Manul ──> selected runtime (no Manul-owned model override)
Caracal embeddings ──> LiteLLM :4000 ("multilingual-e5-base")
                                  └──> Ollama :11434
Caracal MCP :3500 ──> Chroma
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
- LiteLLM exposes exactly one chat model group: `free-cloud`.
- A chat completion succeeds through LiteLLM using `model: free-cloud`.
- When Caracal's local embedding route is enabled, LiteLLM also has the
  embedding-only `multilingual-e5-base` alias backed by Ollama; it is never
  used for chat.
- OpenCode main model, small model and generated role agents use the
  configured catalog selector `litellm/freeLLMAPI`.
- OpenClaw uses `litellm/free-cloud`.
- Manul does not select or override a model; OpenCode tasks use the operator's
  OpenCode configuration.
- No additional LiteLLM chat groups, chat aliases, direct chat providers or
  fallback routes are configured. The separate `multilingual-e5-base`
  embedding-only alias is allowed only for Caracal/Ollama.
- Caracal RAG is installed under `~/.caracal` with its own Python virtual environment; source remains at `~/.caracal-rag`.
- Caracal credentials, embedding endpoint, Chroma settings, and `caracal-rag check` are valid.
- The configured knowledge sources `fiteo-docs` and `quickmvi-readme` are indexed successfully.
- `aicode` waits for Ollama HTTP readiness, starts LiteLLM next, then starts Chroma and launches Caracal MCP in the background. Caracal embedding/MCP readiness is non-blocking for Manul and OpenCode startup; `opencode mcp list` is an advisory one-shot probe.


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

- The only LiteLLM chat model group is `free-cloud`, backed by FreeLLMAPI
  `openai/auto`.
- OpenCode main/small models and generated OpenCode role agents use
  `litellm/freeLLMAPI` for the catalog key `freeLLMAPI`; its upstream
  `modelID` is the LiteLLM group `free-cloud`.
- OpenClaw uses its own selector `litellm/free-cloud`.
- Manul does not select a model or pass `--model`; it uses the selected
  runtime's own configuration.
- Do not add chat aliases such as `big-pickle` or
  `deepseek-v4-flash-free`.
- Do not add direct Groq, Cerebras, Gemini, Mistral, OpenRouter or OpenCode Zen
  chat routes. Ollama is allowed only for the dedicated
  `multilingual-e5-base` embeddings alias.
- Do not configure `router_settings.fallbacks` or `completion_model`.
- LiteLLM chat retries may retry the same `free-cloud` group but must never
  fail over to another chat model group.
- LiteLLM needs `FREELLMAPI_API_KEY` and `LITELLM_MASTER_KEY`; upstream chat
  provider credentials stay in FreeLLMAPI.
- Caracal's embedding requests use the separate
  `multilingual-e5-base` model alias and local Ollama backend; do not route
  those requests through FreeLLMAPI's chat model.

## Operator shell environment and Manul

The operator's existing `~/.zshrc` is the single source of truth for exported
shell settings used by interactive tools and unattended Manul tasks. Keep
`PATH`, OpenCode binary/config selection, provider variables and tool paths
there. Do not duplicate provider settings in `~/.zshenv`, `~/.bashrc` or
`~/.manul/.env`. The only OpenCode-specific value allowed in
`~/.manul/.env` is the non-secret `OPENCODE_CONFIG` path as an unattended
fallback; a value exported by `~/.zshrc` takes precedence.

Manul's installed Zsh integration is sourced from `~/.zshrc`. Interactive
commands inherit that environment directly. Direct and unattended entrypoints,
including cron/watchdog and the daemon, use the canonical
`manul-zsh-bootstrap.sh` helper, which runs `zsh -ic` to load the same
`~/.zshrc` before executing the Bash runtime. The readiness marker prevents
nested Zsh shells for already initialized interactive commands.

`~/.manul/.env` is not a second shell/provider configuration. It may hold
Manul-specific integration fallbacks (such as the dedicated Manul Fiteo
credential) and the non-secret `OPENCODE_CONFIG` path for unattended runs.
It must not contain provider API keys, model choices or copies of provider
configuration. Shell-exported values always win.

A service-specific environment file may still supply credentials to the
service process that owns them (for example, LiteLLM's private service
environment). It must not be used as an alternative PATH or Manul shell
configuration. Any provider value required by unattended Manul workers must
also be available in the Zsh environment loaded by `zsh -ic`.

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
sudo apt update && sudo apt upgrade -y && sudo apt install -y curl git jq unzip build-essential python3-pip python3-venv zsh

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
source ~/.zshrc
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

Export the LiteLLM service credentials in the operator's existing
`~/.zshrc` (do not create a second environment file containing duplicate
values):

```bash
export LITELLM_MASTER_KEY=<generate-a-long-random-key>
export FREELLMAPI_API_KEY=<your-FreeLLMAPI-unified-key>

# Keep this only when the operator OpenCode config uses providers.opencode.
export OPENCODE_API_KEY=<your-OpenCode-Console-key>
```

`OPENCODE_API_KEY` is OpenCode Console authentication, not an OpenCode Go
selector. Keep the operator's `providers.opencode` section and its
`{env:OPENCODE_API_KEY}` reference intact when that provider is configured.

After editing `~/.zshrc`, load the updated exports into the current terminal
with `source ~/.zshrc`. Manul's unattended bootstrap loads the same file itself.

The `aicode` launcher starts LiteLLM as a child process and passes these
exports through. Keep the existing shell file private and never print these
values. A separately managed systemd service would need its own service
environment, but that is not the local aicode-managed setup described here.

Create or update `~/litellm/config.yaml` with the following model entries.
The chat group is `free-cloud`; the local embedding alias is optional and
must only be enabled when Caracal uses Ollama embeddings:

```yaml
model_list:
  # The only chat-completion model group.
  - model_name: free-cloud
    litellm_params:
      model: openai/auto
      api_base: http://127.0.0.1:3001/v1
      api_key: os.environ/FREELLMAPI_API_KEY

  # Caracal-only embeddings alias; not a chat model or fallback.
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

Do not add `router_settings.fallbacks`, `completion_model`, or other chat
groups. The `multilingual-e5-base` entry is the sole purpose-specific
embedding alias and must not be exposed as a chat model.

Load the service credentials into the LiteLLM process and reload the existing
service using its normal service manager; do not start a second proxy process.
Caracal's embedding client must select `multilingual-e5-base` through the
LiteLLM embeddings endpoint, while chat clients continue to select only
`free-cloud`.

**Healthchecks**

```bash
curl -fsS http://127.0.0.1:3001/v1/models \
  -H "Authorization: Bearer $FREELLMAPI_API_KEY"

curl -fsS http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

Verify a successful chat completion with `model: free-cloud`. If Caracal's
embedding alias is enabled, verify an embedding request with
`model: multilingual-e5-base` and confirm it reaches local Ollama. LiteLLM
may list both configured IDs; the invariant is exactly one chat model group,
not exactly one model ID across chat and embeddings. If chat fails, inspect
FreeLLMAPI/LiteLLM logs; do not add chat fallbacks.

### Multi-device

Repeat the same setup on each device. Use `127.0.0.1:3001` only when FreeLLMAPI runs on that same device.

## Step 6 — Install globalskills (agents + skills)

The environment ships with shared skills (`~/.globalskills/skills`) and OpenCode agents (`~/.globalskills/agents`). OpenCode only reads agents from `~/.config/opencode/agents/`, so they must be symlinked — `install.sh` does this automatically. This must run on **every** machine (Desktop and Laptop) before configuring OpenCode.

```bash
# Existing installation: update the source and all managed native skill/agent copies.
if [ -d ~/.globalskills ]; then
  if command -v globalskills >/dev/null 2>&1; then
    globalskills update
  else
    git -C ~/.globalskills pull --ff-only
    bash ~/.globalskills/install.sh
  fi
else
  git clone git@github.com:mariuszmarzec/globalskills.git ~/.globalskills \
    || git clone https://github.com/mariuszmarzec/globalskills.git ~/.globalskills
  bash ~/.globalskills/install.sh
fi
```

**Healthcheck:**

```bash
test -e ~/.config/opencode/agents/orchestrator.md && echo "agents OK"
test -e ~/.agents/skills/wsl-ai-dev-autopilot-multi-device/SKILL.md && echo "skills OK"
```

*If SSH fails on a fresh machine (no key deployed), fall back to the HTTPS clone URL shown above.*

Globalskills and the standalone Manul runtime are updated independently. On an
existing Manul installation, run `manul --update` after `globalskills update`
to update the daemon, adapters and Manul environment bootstrap from the
standalone `mariuszmarzec/manul` repository. No manual runtime symlink edits
or direct installer invocation are required.


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
```

The operator's existing `~/.zshrc` remains the only persistent PATH
configuration. Invoke the Caracal CLI by its explicit path
(`~/.caracal/bin/caracal-rag`) in setup commands, or add its directory once
to that existing PATH if interactive convenience is required.

Configure Caracal interactively so credentials are entered into hidden prompts, not shell history or process arguments:

```bash
"$HOME/.caracal/bin/caracal-rag" setup
```

For this environment, Caracal embeddings use the local LiteLLM alias
`multilingual-e5-base`, which routes to Ollama's
`qllama/multilingual-e5-base` model on port `11434`. Configure Caracal's
embedding client to call the local LiteLLM OpenAI-compatible endpoint on
`127.0.0.1:4000/v1` with model `multilingual-e5-base`. Do not select
FreeLLMAPI's cloud embedding catalogue or `auto` for this local route. The
Caracal key and MCP access token are stored in
`~/.caracal/config/secrets.yaml` with restrictive permissions. Confirm
`~/.caracal/config/sources.yaml` points to the intended embedding endpoint,
Chroma host/port/collection, and includes both knowledge sources:

- `fiteo-docs` — API Markdown documents from `mariuszmarzec/fiteo/docs/api/` on `master`.
- `quickmvi-readme` — `https://raw.githubusercontent.com/mariuszmarzec/QuickMVI/develop/README.md`, covering QuickMVI library usage at README level.

The installer preserves an existing `sources.yaml`; updating `config/sources.example.yaml` does not merge new sources into an already-installed config. If `quickmvi-readme` is missing, add this item under the existing `sources:` list (do not create a duplicate `sources:` key):

```yaml
  - name: quickmvi-readme
    type: markdown
    url: https://raw.githubusercontent.com/mariuszmarzec/QuickMVI/develop/README.md
```

Defaults in the template include FreeLLMAPI at `http://127.0.0.1:3001/v1`,
LiteLLM at `http://127.0.0.1:4000/v1`, Ollama at
`http://127.0.0.1:11434`, Chroma at `127.0.0.1:3400`, and MCP at
`127.0.0.1:3500/mcp`; change them only when the deployment really uses
different endpoints. Caracal embeddings use the separate LiteLLM
`multilingual-e5-base` alias; chat continues to use `free-cloud`.

```bash
"$HOME/.caracal/bin/caracal-rag" check
"$HOME/.caracal/bin/caracal-rag" index --source fiteo-docs
"$HOME/.caracal/bin/caracal-rag" index --source quickmvi-readme
"$HOME/.caracal/bin/caracal-rag" check
```

**Healthcheck:** both `check` calls succeed, indexing completes, and `~/.caracal/config/secrets.yaml` has mode `0600`. Do not start MCP or claim setup is complete if credentials, embedding-model validation, or Chroma connectivity fails; fix the reported dependency and rerun the check.

The authenticated MCP server is launched by `aicode` in the background after Ollama, LiteLLM, and Chroma startup have been initiated. Keep `mcp.host: 127.0.0.1`; never expose the token-authenticated listener on a public interface. Startup does not wait for `caracal-rag check` or the OpenCode MCP connection: embedding warmup may continue while Manul and OpenCode start. The launcher tracks only its own PID in `~/.caracal/run/mcp.pid`, logs to `/tmp/caracal-mcp.log`, and does not kill an unknown process that happens to use the configured port.


## Step 8 — Configure OpenCode

Use `litellm/freeLLMAPI` for both main and small chat requests. This selector
must match the model key under `providers.litellm.models`; the OpenCode
entry's `modelID` remains `free-cloud`, the LiteLLM model-group name. Merge the
following settings into the existing `~/.config/opencode/opencode.json`; do not
replace existing MCP servers, permissions, provider authentication or
unrelated settings.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "litellm/freeLLMAPI",
  "small_model": "litellm/freeLLMAPI",
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
        "freeLLMAPI": {
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

The OpenCode selectable model ID is `litellm/freeLLMAPI`: the provider key is
`litellm`, the configured model-catalog key is `freeLLMAPI`, and its upstream
`modelID` is `free-cloud`. These identifiers have different purposes: the
catalog key is used in the OpenCode selector, while `modelID` is sent to
LiteLLM. Do not rename either value to an unrelated alias such as
`big-pickle`.

Keep only the `free-cloud` chat entry under the LiteLLM provider. Remove stale
chat aliases and direct chat routes, but preserve the separate LiteLLM
`multilingual-e5-base` embedding alias for Caracal. Preserve existing Caracal,
Fiteo and Todo MCP servers, permissions and unrelated provider authentication.
Do not remove `providers.opencode` or `OPENCODE_API_KEY` as a workaround for
an OpenCode Go subscription message: OpenCode Console authentication and the
OpenCode Go provider are distinct. Diagnose the explicitly selected model and
effective config instead.

**Healthcheck:** run a short OpenCode task that invokes a tool and verify it completes through `litellm/freeLLMAPI`. If the FreeLLMAPI auto pool cannot handle tool calls, fix that pool; do not add another LiteLLM model.


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

On each startup, `aicode` waits for the Ollama HTTP API, starts LiteLLM next, then starts/reuses Chroma and launches its authenticated Caracal HTTP MCP in the background. It does not wait for `caracal-rag check`, embedding warmup, or the OpenCode MCP connection before continuing with Manul and OpenCode; a short `opencode mcp list` probe is diagnostic only. The operator-owned OpenCode JSON/JSONC config must already contain the static V2 entry `mcp.servers["caracal-rag"]` with the hardcoded loopback URL `http://127.0.0.1:3500/mcp` and the `{env:CARACAL_ACCESS_TOKEN}` bearer-token placeholder. Keep this Caracal entry intact during updates and migrations; do not replace its URL with `{env:CARACAL_MCP_URL}`. `aicode` never generates, migrates, backs up, or rewrites that config. It points OpenClaw's ACPX `opencode` harness at `~/.globalskills/aicode/opencode-acp-caracal.sh` and sets `plugins.entries.acpx.config.probeAgent: "opencode"` so ACPX startup healthchecks validate this exact harness. Before each ACP session, the wrapper resolves the current local endpoint/token, exports `CARACAL_MCP_URL`, `CARACAL_ACCESS_TOKEN` and `OPENCODE_CONFIG`, and requires `opencode mcp list` to report Caracal connected before it executes `opencode acp`; this is an execution-time tool prerequisite, not an `aicode` startup gate. Manul's direct OpenCode adapter performs the same provider refresh for task processes started by a long-running daemon. This keeps credentials on the process that actually owns Caracal tools and avoids duplicating Caracal as a native OpenClaw MCP server. The ACPX plugin must already be enabled. A delayed or unavailable Caracal service is logged but does not prevent the general startup sequence; Caracal-dependent tool calls become available when its MCP is ready. Todo Desktop MCP remains optional: a missing/unconnected Todo server never blocks a session. The launcher reuses a healthy Caracal process only when the PID file and command line prove it owns that process; it will not kill an unrelated process or send credentials to an unverified endpoint. See `/tmp/caracal-mcp.log` for startup errors.

```bash
globalskills update
grep -qF "alias aicode='~/.aicode/aicode'" ~/.zshrc || echo "alias aicode='~/.aicode/aicode'" >> ~/.zshrc
source ~/.zshrc
aicode
```


# FreeLLMAPI integration

FreeLLMAPI is the only upstream used by LiteLLM for chat completions.

1. Run FreeLLMAPI locally and bind it to loopback (`127.0.0.1:3001`).
2. Configure the upstream provider pool and unified API key inside the FreeLLMAPI dashboard.
3. Export the unified key as `FREELLMAPI_API_KEY` in the operator's existing `~/.zshrc`.
4. Configure the only LiteLLM chat group: `free-cloud`, with
   `model: openai/auto`.
5. Configure OpenCode main/small models and generated OpenCode role agents to
   request `litellm/freeLLMAPI`. Configure OpenClaw to request
   `litellm/free-cloud`. Manul does not select or override a model; its
   OpenCode adapter relies on the operator's OpenCode configuration.
6. When Caracal uses local embeddings, preserve the separate
   `multilingual-e5-base` embedding alias routed to Ollama.

The FreeLLMAPI catalogue may contain multiple upstream models; this does not
mean LiteLLM should expose multiple chat groups. LiteLLM's `model_list` may
contain the one `free-cloud` chat group plus the purpose-specific
`multilingual-e5-base` embedding entry. Do not add more chat model groups or
fallback chains.


# Final Validation

Verify:

- FreeLLMAPI responds at its loopback `/v1/models` endpoint.
- LiteLLM responds on port 4000; `free-cloud` is the only chat model group.
- When enabled for Caracal, `multilingual-e5-base` is present as a separate
  embedding-only alias and a test embedding request reaches Ollama.
- A chat completion succeeds through LiteLLM with `model: free-cloud`.
- OpenCode uses `litellm/freeLLMAPI` for main and small model.
- Generated Globalskills OpenCode agents use the matching selector
  `litellm/freeLLMAPI`.
- OpenClaw's default model is `litellm/free-cloud` and a test turn succeeds.
- Manul does not pass `--model` or add its own model config; its OpenCode
  execution respects the operator's OpenCode config.
- No chat fallback chain, direct LiteLLM chat provider, extra chat group or
  OpenCode Zen model is required.
- PostgreSQL/LiteLLM database health is verified when `database_url` is configured.
- Caracal `check` and source indexing succeed; authenticated MCP responds on loopback.
- `opencode mcp list` reports Caracal connected when launched through `aicode`.
- OpenClaw ACPX points the `opencode` harness at `~/.globalskills/aicode/opencode-acp-caracal.sh`.
- The ACP wrapper verifies Caracal with the current secret, then starts `opencode acp`.
- Manul's OpenCode adapter injects Caracal into its task-local config and requires the MCP to be connected.

Only then report:

> Installation completed successfully. LiteLLM exposes one chat group,
> `free-cloud`, backed by FreeLLMAPI `openai/auto`. OpenCode and its generated
> role agents use the catalog selector `litellm/freeLLMAPI`; OpenClaw uses
> `litellm/free-cloud`. Manul does not override OpenCode model selection.
> When enabled, Caracal uses the separate `multilingual-e5-base` LiteLLM
> embedding alias backed by local Ollama, plus its authenticated MCP service.