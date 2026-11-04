# Global Skills Repository

Shared Agent Skills and canonical multi-runtime agent definitions.
Each skill lives in its own folder with a `SKILL.md` definition file. Each agent
has one canonical `agents/<name>.md` source; the installer generates native
OpenCode and GitHub Copilot agent files from that source.

## Quick Install

```bash
wget -qO /tmp/install-globalskills.sh https://raw.githubusercontent.com/mariuszmarzec/globalskills/master/install.sh && bash /tmp/install-globalskills.sh
```

This clones/updates `~/.globalskills`, installs native skills and generates
agents for OpenCode and GitHub Copilot, then prepares the standalone Manul
source at `~/.manul-repo` and runtime under `~/.manul`.

Native install destinations:

- `~/.agents/skills` — one shared skills copy discovered by OpenCode, GitHub Copilot in VS Code, and Manul.
- `~/.config/opencode/agents` — generated OpenCode agent files.
- `~/.copilot/agents` — generated GitHub Copilot agent files.
- `~/.local/bin/globalskills` — CLI entry point (single-file symlink).
- `~/.aicode/aicode` — maintained launcher (single-file symlink; existing launchers are backed up).
- `~/.manul-repo` — standalone Manul source; runtime state, configuration, database, logs, and workspaces remain under `~/.manul`.

Skills are copied as complete directories, including scripts and references.
Agents are generated from one canonical source file into each runtime's native
Markdown format. Installed resources are tracked in
`~/.local/state/globalskills/manifest.json` (or
`$XDG_STATE_HOME/globalskills/manifest.json`).

Add the CLI directory to your shell PATH once:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Updating

```bash
globalskills update --check
globalskills update
globalskills status
globalskills rollback skill:my-skill --runtime all
globalskills rollback agent:reviewer --runtime all
```

Updates fast-forward the Globalskills source checkout when upstream changes
are available. Managed resources are updated only when their installed hashes
still match the previous manifest. Local edits and unmanaged files are
preserved; collisions are reported instead of overwritten. Previous managed
versions are backed up for rollback. The installer never changes Manul's
runtime database or task data.

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
- The launcher sends an unauthenticated MCP `initialize` handshake followed by
  the read-only `tools/list` request. HTTP 401/403 or any invalid/incomplete MCP
  response is treated as unavailable; an HTTP status alone never marks Todo as
  connected.
- Todo Desktop MCP uses no bearer token. No Todo credential is loaded or passed
  to OpenCode or persisted in the Manul runtime.
- Manul probes the local endpoint with the same unauthenticated MCP handshake
  and adds todo-local to the task-scoped config only when the handshake
  succeeds. It verifies todo-local connected before starting a task when that
  optional MCP was enabled; unrelated tasks continue when Todo Desktop is
  unavailable.

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

`aicode` always registers the remote `fiteo` MCP server in the global OpenCode
config. This is the interactive/operator connection and uses `FITEO_BASE_URL`
plus `FITEO_PAT`. It is independent of credentials used by standalone Manul
task workers.

Keep the operator variables exported in your existing `~/.zshrc`:

```bash
export FITEO_BASE_URL="https://your-fiteo-backend"
export FITEO_PAT="YOUR_PAT"
```

For the standalone Manul `todo_remote_mcp` source and task-scoped Fiteo MCP,
provide the dedicated Manul-account token through `FITEO_MANUL_PAT` in the
local environment before Manul bootstrap. Manul persists this token in the
mode-600 `~/.manul/.env` for unattended workers. Never copy the
operator PAT into this variable and never fall back to the operator PAT when
the Manul token is missing. Global `aicode` continues to use `FITEO_PAT`;
only Manul remote Todo access uses `FITEO_MANUL_PAT`.

Manul-created remote Todo tasks and report subtasks are shared with the
configured recipient using `EDITOR_AND_VIEWER`. Set the non-secret numeric
`FITEO_MANUL_SHARE_USER_ID` in the environment used to bootstrap Manul. This
recipient ID is separate from `manulUserId`, which identifies the Manul account
whose shared tasks the remote adapter discovers.

The OpenClaw ACP wrapper keeps the operator token for the global OpenCode
MCP session. It must not replace it with the dedicated Manul token used by
task workers. Token values are never written to OpenCode JSON or committed
to repository files.

## Todo task sources for Manul

Manul has two independent Todo source adapters; enable them individually in `~/.manul/config.json` under `taskSources` (see [Manul config example](https://github.com/mariuszmarzec/manul/blob/main/skills/manul-github-bot/config.json.example) for the complete examples).

- `todo_local_mcp` connects to `http://127.0.0.1:8765/mcp` on native Linux/macOS and uses the WSL relay at `http://127.0.0.1:8766/mcp` only when direct loopback is unavailable. It uses no bearer token and queues active root tasks only after an unauthenticated MCP initialize/read-only tools-list handshake succeeds.
- `todo_remote_mcp` talks to Fiteo's backend `/mcp` endpoint over HTTPS. It queues active root tasks shared with the configured numeric `manulUserId` using `EDITOR_AND_VIEWER` permission, but executes them only when `/manul` appears in the root description or a nested subtask. Use the dedicated `FITEO_MANUL_PAT` (never fall back to `FITEO_PAT`); Manul-created tasks and report subtasks are shared with `FITEO_MANUL_SHARE_USER_ID`.

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
| `agent-orchestration` | Rules for the Globalskills multi-agent orchestration system across OpenCode and GitHub Copilot. Use when running as the orchestrator, deciding which role agent to dispatch, selecting model tiers, escalating, or producing the routing report. Applies to architect, coder, reviewer, debugger, researcher, tester, security, performance, and refactorer roles. |
| `ai-commit-attribution` | Preserve the human developer as the Git commit author and add a Co-authored-by trailer to every AI-created commit. Use whenever creating a Git commit. Never change Git author config, never use --author, and always append the OpenCode <opencode@ai.local> trailer (or the identity of the active agent outside OpenCode). |
| `android-clean-architecture` | Android clean architecture patterns for layered applications using Kotlin, coroutines, caching strategies, MVI state management, and reactive programming. |
| `chatgpt-supervised-workflow` | Enforce an evidence-driven execution workflow for tasks originating from ChatGPT. Use when a task contains a ChatGPT chatId or explicitly identifies ChatGPT as the supervisor. Focus on preserving task context, making small verifiable changes, independently validating results, and never claiming completion without evidence. |
| `feature-branching-strategy` | Branching strategy for changes made by an AI agent. Use whenever pushing code changes to a repository (except the ~/.globalskills repo) — always create a feature/<ISSUE_NUMBER-if-exists>-<DESCRIPTION> branch, or bugfix/<DESCRIPTION> for bug fixes, and never push directly to the main branch. |
| `fiteo-access` | Use whenever an agent needs to connect to a running Fiteo backend, determine its runtime base URL, use the Manul account, or make authenticated Fiteo HTTP requests. Runtime settings come from environment variables; never hardcode or disclose their values. |
| `fiteo-backend-api` | Use whenever the user asks about Fiteo backend API endpoints or contracts, including routes, HTTP methods, request/response payloads, DTOs, query/path parameters, authentication, validation, status codes, pagination, or implementing/reviewing code that calls or exposes a Fiteo endpoint. Before answering, search the indexed Fiteo API documentation through the caracal-rag MCP server. |
| `freellmapi-environment` | Configure and operate a local FreeLLMAPI environment with LiteLLM and related tools. Use when aggregating local cloud-provider APIs behind a single OpenAI-compatible endpoint. |
| `github-selfhosted-runner` | Provision a self-hosted GitHub Actions runner in Docker on any Linux host (WSL2, VM, bare metal). Handles image build, token refresh, and container lifecycle. |
| `globalskills-repository` | Manage the global skills repository at ~/.globalskills/skills. Use when creating new skills, moving skills between locations, or organizing the shared skill repository. |
| `karpathy-guidelines` | Behavioral guidelines to reduce common LLM coding mistakes. Use when writing, reviewing, or refactoring code to avoid overcomplication, make surgical changes, surface assumptions, and define verifiable success criteria. |
| `kotlin-code-formatting` | Code formatting and style rules for Kotlin. Use when writing, editing, or reviewing Kotlin code in an Android/Gradle project that enforces these rules via detekt (config/detekt/detekt.yml) and Kotlin official style. Run ./gradlew detekt to verify. |
| `litellm-db-setup` | Configure LiteLLM to use a local PostgreSQL database for its UI/auth features. Use when setting up LiteLLM with database support, fixing LiteLLM database connection issues, or initializing the litellm PostgreSQL user and database. |
| `manul-github-bot` | Operate Manul, the standalone GitHub task orchestrator. Use this skill for Manul commands, status, task submission, configuration, runtime troubleshooting, and integration with globalskills agents, aicode, and Todo MCP. |
| `navigation-setup` | Implement and configure application navigation using NavigationStore, NavigationHost, Router, NavigationEntry, and nested navigation flows. |
| `openclaw-knowledge` | OpenClaw general knowledge + current known-good setup. Use before making changes to avoid incorrect assumptions about OpenClaw, authentication, Gateway lifecycle, systemd, plugins, and state separation. |
| `pr-description-management` | Manage GitHub Pull Request descriptions - create PRs with proper descriptions and update descriptions when pushing changes. Uses gh CLI for all PR operations. Follows feature-branching-strategy for branch naming. |
| `quickmvi-usage-testing` | QuickMVI usage and testing guidelines for Kotlin Multiplatform MVI applications. Based on QuickMVI library patterns, testing utilities, and best practices extracted from the QuickMVI project. |
| `review-strategy` | Shared methodology for high-quality code review. Defines how reviewers understand requirements, inspect implementation, test behavior, identify risks, and produce evidence-based findings. |
| `unit-testing-android` | Android-specific unit and integration testing practices for JVM, instrumented, and UI tests. Use when designing or implementing tests for Android applications. |
| `unit-testing-language-agnostic` | Language-agnostic unit and integration testing principles. Use when designing, writing, or reviewing automated tests in any language or framework. |
| `wsl-ai-dev-autopilot-multi-device` | Fully automated WSL2 AI dev environment (OpenCode + OpenClaw compatible). Supports multi-device installation (PC + laptop), hardware-aware model selection, strict healthchecks, self-healing, multi-model LiteLLM routing, local Ollama, and Caracal RAG MCP integration. Use when setting up or repairing a WSL2 AI dev environment with Ollama, LiteLLM, OpenCode, OpenClaw, and Caracal RAG. |
| `yt-dlp-downloader` | Robust YouTube downloading and audio extraction via yt-dlp with anti-bot bypass flags (--user-agent, --extractor-args, --no-check-certificates) and oEmbed fallback search. Use when downloading videos or MP3s from YouTube URLs with yt-dlp to guarantee success. |

## Agents (multi-agent orchestration)

Canonical agent definitions live in `agents/<name>.md`. Each file contains one shared prompt body, Globalskills metadata, and separate `[opencode]` / `[copilot]` configuration tables. The installer generates native runtime files; never edit generated files directly. OpenCode keeps its configured LiteLLM model mapping. Copilot agents inherit the model selected in VS Code unless a Copilot-specific model is explicitly configured. Roles define WHAT to do; model tiers and runtime adapters define HOW to execute them.

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

[Manul](https://github.com/mariuszmarzec/manul) is maintained as a standalone
GitHub task orchestrator. Its daemon, task queue, SQLite state, workspace
isolation, agent-runtime adapters, installers, and runtime test suite live in
the separate `mariuszmarzec/manul` repository.

This repository retains the OpenCode skill instructions, global agent roles,
project-repository catalog, and the `aicode` launcher integration. The
`install.sh` script installs or updates both repositories independently.

```text
        /\_/\\
       ( o.o )
        > ^ <
```

For runtime installation, configuration, CLI usage, task-source adapters, runtime/role routing, and troubleshooting, see the [Manul repository README](https://github.com/mariuszmarzec/manul) and its [Manul skill guide](https://github.com/mariuszmarzec/manul/blob/main/skills/manul-github-bot/SKILL.md).

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
