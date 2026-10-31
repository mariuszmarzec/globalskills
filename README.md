# Global Skills Repository

Shared skills and OpenCode agents for the multi-agent orchestration system.
Each skill lives in its own folder with a `SKILL.md` definition file; each
agent lives in `agents/<name>.md`.

## Quick Install

```bash
wget -qO /tmp/install-globalskills.sh https://raw.githubusercontent.com/mariuszmarzec/globalskills/master/install.sh && bash /tmp/install-globalskills.sh
```

This clones the repo to `~/.globalskills` and symlinks:

- `~/.agents/skills -> ~/.globalskills/skills`
- `~/.config/opencode/agents -> ~/.globalskills/agents`
- `~/.aicode/aicode -> ~/.globalskills/aicode/aicode` (the installer backs up an existing launcher instead of overwriting it)

Skills are loaded by OpenCode via `skills.paths` in `~/.config/opencode/opencode.json`.
Agents are discovered from `~/.config/opencode/agents/` (the symlink above).

## Updating

```bash
git -C ~/.globalskills pull
```

## macOS runtime prerequisites

The Manul/aicode runtime supports macOS when its process and filesystem tools
are installed through Homebrew. Install the required packages once:

The Manul installer also requires the GitHub CLI (gh), jq, SQLite (sqlite3),
and Python 3. Install at least one supported agent runtime (OpenClaw, OpenCode,
Codex, or Claude Code) separately.

```bash
brew install bash coreutils util-linux gh jq sqlite python
```

The platform bootstrap automatically prepends Homebrew Bash, GNU Coreutils
(`timeout`, `stat`, `realpath`, `sha256sum`) and util-linux
(`flock`, `setsid`) to PATH. It re-executes the launcher, daemon and
watchdog under Homebrew Bash 4+ where necessary. The watchdog repeats this
bootstrap when started by cron, whose PATH does not inherit interactive shell
configuration. No Linux VM, Docker, WSL, or Todo bridge is needed on macOS.

## Todo Desktop MCP (cross-platform)

Todo Desktop exposes its Streamable HTTP MCP endpoint on loopback at
`http://127.0.0.1:8765/mcp`. Native Linux and macOS clients connect directly;
they do not need PowerShell, WSL networking, a relay, or a bridge. The endpoint
is available only while Todo Desktop is running, `todo.localMcpServer` is
enabled, and a user session is active.

When OpenCode runs inside WSL while Todo Desktop runs in Windows, aicode first
tries the direct loopback endpoint (which works with mirrored/forwarded WSL
networking). Only when that probe fails does it start the existing WSL-to-
Windows bridge and expose the endpoint to OpenCode and Manul at
`http://127.0.0.1:8766/mcp`.

Export TODO_LOCAL_MCP_TOKEN in your shell (for example, from ~/.zshrc);
alternatively, set it in ~/.config/opencode/todo-mcp.env. An already-exported
token takes precedence:

```bash
export TODO_LOCAL_MCP_TOKEN='YOUR_TODO_DESKTOP_TOKEN'
```

On the next aicode launch:

- The WSL relay listens on 127.0.0.1:8766 for OpenCode and Manul, and on the
  current WSL interface address at port 18766 for reverse channels.
- The reverse listener accepts channels only from the current Windows WSL
  gateway address. It does not bind to 0.0.0.0.
- The Windows helper initiates a small pool of outbound TCP connections to WSL.
  Each channel carries one HTTP request to Todo Desktop's existing
  127.0.0.1:8765 MCP endpoint; Windows does not open an inbound bridge port.
- The Windows helper forwards only HTTP GET/POST/DELETE requests to /mcp and
  rewrites Host/Origin headers for Todo's DNS-rebinding protection.
- The launcher sends an unauthenticated probe and enables the OpenCode MCP entry
  only after Todo rejects it with HTTP 401. Todo still validates the Bearer
  token on every MCP request.
- The current token is refreshed in ~/.manul/.env so unattended Manul tasks
  can use the same MCP entry.
- Manul's OpenCode adapter reloads the token from ~/.manul/.env for each task,
  probes the bridge, and adds todo-local to the task-scoped config only when
  the bridge is reachable. It verifies todo-local connected before starting
  the task when that optional MCP was enabled; unrelated tasks continue when
  Todo Desktop is unavailable.

The Windows helper serializes Ensure operations, finds all connector processes
for the target relay (even when bridge.json is missing or stale), and stops
stale or duplicate instances before starting one replacement. A per-relay
Windows mutex also prevents a second Connect process from competing for the
same channel pool. The WSL relay uses a larger TCP accept backlog for brief
reconnect bursts and immediately resets rejected excess channels.

The bridge does not change Todo's listener, disable DNS-rebinding protection,
add Windows Firewall rules, or listen on Windows LAN interfaces. Todo Desktop
must be running with todo.localMcpServer enabled. Windows bridge logs are
under %LOCALAPPDATA%/GlobalSkills/TodoMcpBridge; the WSL log is
~/.cache/globalskills/todo-mcp-bridge/bridge.log. The relay is recreated when
the WSL address or bridge code changes.

## Fiteo backend MCP (remote)

`aicode` always registers the remote `fiteo` MCP server in OpenCode, including
the global config and every Manul task-scoped config. It is not conditional on
the `todo_remote_mcp` task source being enabled. The server uses Streamable HTTP
at `{FITEO_BASE_URL}/mcp` and authenticates each request with a Fiteo PAT.

Set both variables in `~/.config/opencode/opencode.env` (or export them before
launching `aicode`):

```bash
FITEO_BASE_URL="https://your-fiteo-backend" # base URL without a trailing slash
FITEO_PAT="YOUR_FITEO_PAT"
```

The MCP entry is still present when either variable is missing, but it cannot
connect until both are configured. `aicode` refreshes the endpoint/PAT pair in
the mode-600 `~/.manul/.env`; Manul reloads the latest pair for each task, and
the OpenClaw ACP wrapper refreshes it before starting an OpenCode session. The
token value is never written into OpenCode's JSON config or repository files.

## Todo task sources for Manul

Manul has two independent Todo source adapters; enable them individually in `~/.manul/config.json` under `taskSources` (see `skills/manul-github-bot/config.json.example` for the complete examples).

- `todo_local_mcp` connects to `http://127.0.0.1:8765/mcp` on native Linux/macOS and uses the WSL relay at `http://127.0.0.1:8766/mcp` only when direct loopback is unavailable. It queues active root tasks whose description contains a line beginning with `/manul`; the token is supplied by `TODO_LOCAL_MCP_TOKEN`.
- `todo_remote_mcp` talks to Fiteo's backend `/mcp` endpoint over HTTPS. It queues active root tasks shared with the configured numeric `manulUserId` using `EDITOR_AND_VIEWER` permission; the PAT is supplied by `FITEO_PAT` (or a configured `tokenEnv`).

Set `allowReportOnly: true` on either Todo source to opt in to informational
tasks using a description line such as:

```text
/manul report Summarize the current state of the project and list the risks
```

Report-only tasks do not need a repository URL or project alias and never create
a checkout, branch, or PR. Manul saves the answer as a completed child task under
the Todo root, reads it back to verify the exact content, and only then completes
the original task tree. A partial create/update is safely reused on retry rather
than producing duplicate result children. The default remains disabled in the
example configuration.

Todo tasks are not assigned to the Todo app repository by default. Manul
resolves their target from an explicit GitHub repository URL or a unique
whole-phrase alias in
`skills/globalskills-repository/project-repositories.json`, then enforces
the operator's `repositoryAllowlist`. Relevant mapped skill contents are
included in the task context. Unknown, ambiguous, or disallowed targets are
not queued; there is no static repository fallback. Keep the project catalog
and aliases current as repositories/projects are added.

Both adapters preserve Todo's returned subtask order and pass the whole nested tree to Manul as ordered steps. Subtasks are not separate Manul queue entries. After the repository work is verified, Manul marks the root and every descendant done through the same MCP source. MCP credentials are persisted only in the mode-600 `~/.manul/.env` for unattended runs; never put token values in the config or repository.

## Skills

| Skill | Description |
|-------|-------------|
| `agent-orchestration` | Rules for the OpenCode multi-agent orchestration system. Use when running as the orchestrator agent, deciding which role agent to dispatch, which model tier fits a task, when to escalate, or how to produce the routing report. |
| `ai-commit-attribution` | Preserve the human developer as the Git commit author and add a Co-authored-by trailer to every AI-created commit. Use whenever creating a Git commit. Never change Git author config, never use --author, and always append the OpenCode <opencode@ai.local> trailer (or the identity of the active agent outside OpenCode). |
| `feature-branching-strategy` | Branching strategy for changes made by an AI agent. Use whenever pushing code changes to a repository (except the ~/.globalskills repo) — always create a feature/<ISSUE_NUMBER-if-exists>-<DESCRIPTION> branch, or bugfix/<DESCRIPTION> for bug fixes, and never push directly to the main branch. |
| `pr-description-management` | Manage GitHub Pull Request descriptions - create PRs with proper descriptions and update descriptions when pushing changes. Uses gh CLI for all PR operations. Follows feature-branching-strategy for branch naming. |
| `github-selfhosted-runner` | Provision a self-hosted GitHub Actions runner in Docker on any Linux host (WSL2, VM, bare metal). |
| `karpathy-guidelines` | Behavioral guidelines to reduce common LLM coding mistakes. Use when writing, reviewing, or refactoring code to avoid overcomplication, make surgical changes, surface assumptions, and define verifiable success criteria. |
| `quickmvi-usage-testing` | QuickMVI usage and testing guidelines for Kotlin Multiplatform MVI applications. Consults Caracal RAG's indexed QuickMVI README for documented usage; verify exact behavior against source and tests. |
| `litellm-db-setup` | Configure LiteLLM to use a local PostgreSQL database for its UI and auth features. Use when setting up LiteLLM database support or fixing LiteLLM database connection issues. |
| `unit-testing-language-agnostic` | Universal unit-testing principles, including whole-value assertions when equality is meaningful |
| `manul-github-bot` | Set up, operate, and debug Manul, the GitHub task orchestrator. Automatic tasks use the configured runtime (OpenClaw by default); explicitly selected canonical roles use the configured role runtime (OpenCode by default). Manul owns task state, workspace isolation, retries, result verification, and GitHub delivery. |
| `chatgpt-supervised-workflow` | Enforce an evidence-driven execution workflow for tasks originating from ChatGPT. Use when a task contains a ChatGPT chatId or explicitly identifies ChatGPT as the supervisor. Focus on preserving task context, making small verifiable changes, independently validating results, and never claiming completion without evidence. |
| `wsl-ai-dev-autopilot-multi-device` | Fully automated WSL2 AI dev environment (OpenCode compatible), including isolated Caracal RAG installation, authenticated MCP startup after LiteLLM, hardware-aware model selection, healthchecks, and multi-model LiteLLM routing. |
| `freellmapi-environment` | Operational notes for running FreeLLMAPI locally and wiring it into LiteLLM (`~/.globalskills/skills/freellmapi-environment/SKILL.md`). |
| `fiteo-access` | Connect to the Fiteo backend using the current `FITEO_BASE_URL`, `FITEO_MANUL_USERNAME`, and `FITEO_MANUL_PASSWORD` environment variables. Never hardcode or print their values. |
| `fiteo-backend-api` | Use for Fiteo backend endpoint/API contract questions and related implementation or review work. Search Caracal RAG's `fiteo-docs` source first; verify current code/tests before claiming implementation behavior. |

## Agents (multi-agent orchestration)

OpenCode agents in `agents/`. Roles define WHAT to do; model tiers define how much reasoning power. Full routing rules, model mapping, and escalation are in the `agent-orchestration` skill.

| Agent | Mode | Default tier | Model | Read-only |
|-------|------|-------------|-------|-----------|
| `orchestrator` | primary | EXPERT | `litellm/big-pickle` | no |
| `architect` | all | EXPERT | `litellm/big-pickle` | edit: ask |
| `coder-cheap` | all | CHEAP | `litellm/groq-llama-8b` | no |
| `coder` | all | NORMAL | `litellm/groq-llama-70b` | no |
| `coder-strong` | all | STRONG | `litellm/deepseek-v4-flash-free` | no |
| `coder-expert` | all | EXPERT | `litellm/big-pickle` | no |
| `reviewer` | all | STRONG | `litellm/deepseek-v4-flash-free` | edit: deny |
| `reviewer-expert` | all | EXPERT | `litellm/big-pickle` | edit: deny |
| `debugger` | all | STRONG | `litellm/deepseek-v4-flash-free` | no |
| `debugger-expert` | all | EXPERT | `litellm/big-pickle` | no |
| `researcher` | all | CHEAP | `litellm/gemini-3.1-flash-lite` | edit: deny |
| `tester` | all | NORMAL | `litellm/groq-llama-70b` | no |
| `security` | all | EXPERT | `litellm/big-pickle` | edit: deny |
| `performance` | all | STRONG | `litellm/gemini-3.6-flash` | edit: ask |
| `refactorer` | all | NORMAL | `litellm/groq-qwen3` | no |

Set `default_agent: "orchestrator"` in `~/.config/opencode/opencode.json` to
route every new session through the orchestrator.

## Manul 🐈

Manul (kot stepowy, Pallas's cat) — the GitHub command bot living in this repo's
skills. Watches configured repositories, reacts to `/manul` in issue/PR
comments, implements tasks on `manul/*` branches, opens PRs, and replies
signed `— manul 🐈`.

```text
        /\_/\\
       ( o.o )
        > ^ <
```

Full setup, runtime/role routing, session continuation, baseline semantics, and troubleshooting: `skills/manul-github-bot/SKILL.md`.

## Skill Benchmarks

Behavioral benchmarks for skills live in `skill-benchmarks/`. They run the real
agent locally against a fresh fixture and use deterministic verifiers to check
the resulting behavior. OpenCode is the current backend behind an adapter so
the benchmark runner can be switched later without changing benchmark cases.

Run a case:

```bash
python3 skill-benchmarks/benchmark.py run --case commit-trailer
```

Compare with and without the skill:

```bash
python3 skill-benchmarks/benchmark.py run --case commit-trailer --mode both
```

Run all non-excluded benchmarks in one diagnostic run:

```bash
python3 skill-benchmarks/benchmark.py run-all --mode both
```

This produces one aggregate report under `skill-benchmarks/output/<run-id>/`
with per-case failures and skill impact signals.

Each live run writes a self-contained report under `skill-benchmarks/output/<run-id>/`, including the with/without-skill comparison, tested `SKILL.md` snapshot, agent output, verifier result, and git artifacts. The output directory is ignored by git.

The benchmark suite is deliberately not wired into CI. Its framework and
adapters have local unit tests with mocks, so those tests do not require an
LLM. New skills should add a benchmark unless the skill is explicitly excluded
in `skill-benchmarks/config.json`.

See `skill-benchmarks/README.md` for the case format and conventions.
