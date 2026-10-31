---
name: manul-github-bot
description: Operate Manul, the standalone GitHub task orchestrator. Use this skill for Manul commands, status, task submission, configuration, runtime troubleshooting, and integration with globalskills agents, aicode, and Todo MCP.
---

# Manul GitHub Bot 🐈

Manul is a standalone GitHub task orchestrator maintained in
[github.com/mariuszmarzec/manul](https://github.com/mariuszmarzec/manul).

## Repository and runtime ownership

- **Manul implementation, installer, adapters, tests, architecture and contracts:** [mariuszmarzec/manul](https://github.com/mariuszmarzec/manul)
- **Canonical local checkout:** `~/.manul-repo/`
- **Canonical runtime scripts:** `~/.manul-repo/skills/manul-github-bot/`
- **Runtime data and configuration:** `~/.manul/`
- **Task database:** `~/.manul/state/manul.db`
- **Provider credentials:** `~/.manul/.env` (mode 600)

This globalskills skill is only the host-side operating guide and integration
contract. Do not implement Manul runtime changes in this repository. Runtime
changes belong in the standalone Manul repository and its CI.

The runtime source checkout and runtime data are independent. Updating or
reinstalling Manul source must not delete the runtime database, task artifacts,
logs, locks, or workspaces.

## Installation and updates

The globalskills installer manages both repositories:

```bash
bash ~/.globalskills/install.sh
```

It updates/clones globalskills to `~/.globalskills` and Manul to
`~/.manul-repo`. Install or repair the runtime from the standalone source:

```bash
export MANUL_CANONICAL_DIR="$HOME/.manul-repo/skills/manul-github-bot"
bash "$MANUL_CANONICAL_DIR/install-manul.sh"
```

The installer prepares `~/.manul` and deploys runtime symlinks. Starting
automation is a separate, intentional action:

```bash
manul start
manul status
manul stop
```

The runtime's default state directory is `~/.manul`; do not change it when
only moving or updating the source repository. Never put API tokens, PATs,
passwords, or machine-specific operator configuration in either Git repo.

## GitHub task commands

Manul reacts to `/manul` commands in configured issue/PR conversations:

| Command | Purpose |
|---|---|
| `/manul run <task>` | Implement a task using the configured automatic runtime |
| `/manul run --agent <role> <task>` | Run using an explicit canonical role |
| `/manul <role> <task>` | Explicit-role shorthand |
| `/manul review-fix <prompt>` | Address review feedback |
| `/manul continue <answer>` | Resume a task blocked on user input |
| `/manul verify <prompt>` | Verify/report without repository delivery |
| `/manul status` | Inspect conversation/task status |
| `/manul close` | Close a conversation |

Automatic runtime selection is configured by
`automation.agentRuntime` (default `openclaw`). Explicit canonical roles
use `automation.roleRuntime` (default `opencode`). Supported runtimes are
`openclaw`, `opencode`, `codex`, and `claude-code`.

## Host integrations owned by globalskills

Global agent role definitions remain in `~/.globalskills/agents/`. Codex and
Claude Code adapters consume those canonical role files; Manul does not keep
another copy.

Project aliases and mapped repository metadata remain in
`~/.globalskills/skills/globalskills-repository/project-repositories.json`.
When a project or alias is added, update that catalog and ensure the Manul
repository allowlist permits the intended target.

The `aicode` launcher uses
`MANUL_CANONICAL_DIR` to load Manul's platform helper, path resolver,
environment helper, installer, and repairer. Todo local MCP endpoint discovery
is shared through Manul's `todo-local-mcp-url.sh`; tokens are stored in the
runtime environment, never in source control.

## Documentation

For the authoritative implementation details, installation requirements,
configuration schema, task-source contracts, adapter behavior, testing,
troubleshooting, and operational invariants, consult:

- [Manul README](https://github.com/mariuszmarzec/manul)
- [Manul skill guide](https://github.com/mariuszmarzec/manul/blob/main/skills/manul-github-bot/SKILL.md)
- [Architecture](https://github.com/mariuszmarzec/manul/blob/main/skills/manul-github-bot/ARCHITECTURE.md)
- [Contracts](https://github.com/mariuszmarzec/manul/blob/main/skills/manul-github-bot/CONTRACTS.md)

Do not edit `manul.db` directly or reset task state as a shortcut for code
changes. Database recovery, queue operations, workspace ownership, and task
lifecycle behavior are owned by the standalone Manul runtime.
