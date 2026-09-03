---
name: manul-github-bot
description: Setup, operate, and reinstall the manul GitHub command bot (OpenClaw + gh). Manul reacts to `/manul` in issue/PR comments, implements the task on a `manul/*` branch, pushes, optionally opens a PR, and replies with comments signed "manul 🐈". Use when installing manul on a (new) machine, changing its config, or debugging it. This skill directory is the canonical source for `poll.sh`, `manul-comments-remove.sh`, `orchestrator.prompt.md`, `watchdog.sh`, `task-recovery.sh`, and `start-manul-automation.sh`.
---

# Manul GitHub Bot 🐈

Manul (kot stepowy, Pallas's cat) is a GitHub command bot driven by OpenClaw.
It watches configured repositories, reacts to the trigger `/manul` in issue
bodies, issue comments, and PR review comments, and implements the requested
task: dedicated branch `<type>/manul/<issue>-<slug>` → commit → push → optional
PR → feedback comments on the **same location** that triggered the task. Every comment/PR manul writes is signed
`— manul 🐈`
(identity: **manul** on GitHub, **OpenClaw** in the console).

**Comment routing:** a task triggered by a PR review comment gets its feedback (🤖 Running, ✅ Done, ❌ Failed) posted as an in-thread reply on that review comment; a task triggered by an issue/PR conversation comment or issue body gets its feedback as a top-level issue/PR comment. Cross-posting (e.g. a review-thread task becoming a top-level PR comment) is a bug.

```
        /\_/\
       ( o.o )   manul 🐈 — GitHub command bot
        > ^ <
```

## Architecture

```
GitHub
  ↓
poll.sh
  ↓
SQLite (single source of truth)
  ↓
queued
  ↓
manul-daemon.sh
  ↓
running
  ↓
heartbeat + lease
  ↓
done / failed

watchdog.sh
  ↓
automatic stale-task recovery
```

**Explicit separation of responsibilities:**

| Component | Responsibility |
|-----------|----------------|
| `poll.sh` | GitHub polling, deduplication and enqueueing only (no recovery) |
| `SQLite manul.db` | single source of truth for all task state |
| `manul-daemon.sh` | consumes queued tasks and executes the orchestrator |
| `watchdog.sh` | ONLY automatic recovery/liveness mechanism (daemon liveness, stale lock removal, heartbeat/lease-based task recovery) |
| `task-recovery.sh` | manual/admin recovery tool only (NOT automatic) |
| `task-health-check.sh` | LEGACY/DEPRECATED; MUST NOT be part of automatic operation |

**Dispatch is synchronous (daemon waits for the agent turn), so runs never
overlap; `lock` is a backstop with 30 min TTL.**

**Manul must remain independently operable from OpenClaw `main`.**

## Task Lifecycle

```text
queued → running → done
                 ↘ failed

running → queued  (watchdog recovery)
```

**State transitions:**

- **queued → running**: atomic claim by `manul-daemon.sh`; `attempts` increments by 1; `heartbeatAt`, `startedAt`, `workerPid`, and `leaseExpiresAt` are set.
- **running → done**: task completed successfully.
- **running → failed**: task failed permanently (after `attempts >= maxAttemptsBeforeFail`).
- **running → queued**: watchdog recovery for stale tasks. **Does NOT increment `attempts`.**

`attempts` counts actual execution attempts and is incremented only when a queued task is claimed for execution (queued → running transition). Recovery from `running → queued` does NOT increment `attempts`.

## Heartbeat / Lease Fields

The `processed_comments` table in SQLite carries the following liveness/lease fields:

| Field | Meaning |
|-------|---------|
| `heartbeatAt` | last heartbeat timestamp updated by the worker |
| `startedAt` | when the task started executing |
| `workerPid` | PID of the worker process |
| `leaseExpiresAt` | when the task lease expires |
| `attempts` | number of actual execution attempts (incremented on claim) |
| `recoveryCount` | number of times the task has been recovered by watchdog |

## Configuration

The current `automation` configuration names are:

```text
heartbeatTimeout
leaseTimeout
maxAttemptsBeforeFail
lockTtl
alerts
```

Do NOT use legacy names `maxTaskRunningTime` or `taskHealthCheckInterval`; they are not read by the current runtime.

## Files (canonical source lives here — symlinked into `/mnt/f/ubuntu-workspace/.openclaw/manul/`)

| Path | Purpose |
|---|---|
| `~/.globalskills/skills/manul-github-bot/SKILL.md` | skill/rules source of truth |
| `~/.globalskills/skills/manul-github-bot/poll.sh` | canonical poller script (symlinked into `/mnt/f/ubuntu-workspace/.openclaw/manul/poll.sh`) |
| `~/.globalskills/skills/manul-github-bot/orchestrator.prompt.md` | canonical orchestrator prompt (symlinked into `/mnt/f/ubuntu-workspace/.openclaw/manul/orchestrator.prompt.md`) |
| `~/.globalskills/skills/manul-github-bot/manul-comments-remove.sh` | comment cleanup script (symlinked) |
| `~/.globalskills/skills/manul-github-bot/watchdog.sh` | automatic recovery/liveness script (symlinked into `/mnt/f/ubuntu-workspace/.openclaw/manul/watchdog.sh`) |
| `~/.globalskills/skills/manul-github-bot/task-recovery.sh` | manual recovery CLI (symlinked into `/mnt/f/ubuntu-workspace/.openclaw/manul/task-recovery.sh`) |
| **`~/.globalskills/skills/manul-github-bot/task-health-check.sh`** | **LEGACY/DEPRECATED — do not install or use in automatic operation** |
| `~/.globalskills/skills/manul-github-bot/start-manul-automation.sh` | startup wrapper for daemon + watchdog cron (symlinked) |
| `~/.globalskills/skills/manul-github-bot/manul-status.sh` | status reporting script (symlinked) |
| `~/.globalskills/skills/manul-github-bot/config.json.example` | configuration template (copy to `/mnt/f/ubuntu-workspace/.openclaw/manul/config.json` and customize) |

### watchdog.sh

`watchdog.sh` is the **only** automatic recovery mechanism.

**Responsibilities:**
1. Start the daemon if it is not running.
2. Detect a stale lock file (age >= `lockTtl`) and remove it (WITHOUT resetting tasks).
3. Recover tasks based on stale heartbeat/lease ONLY.

**Schedule:** Runs every 5 minutes via cron.

### Task Recovery CLI

`task-recovery.sh` provides **manual intervention** capabilities for stuck manul tasks:

**Commands:**
- `--list-stuck` — List all tasks stuck in 'running' state
- `--reset <id>` — Reset a specific task commentId to 'queued'
- `--mark-failed <id>` — Mark a specific task commentId as 'failed'
- `--reset-all` — Reset ALL running tasks (requires confirmation)
- `--health-check` — Run comprehensive health check with recommendations

### Task Health Monitor (LEGACY/DEPRECATED)

`task-health-check.sh` is **legacy/deprecated** and uses obsolete concepts such as `maxTaskRunningTime` and `queue.json` consistency checks. It MUST NOT be installed or run as part of automatic operation.

### Automation Startup Helper

`start-manul-automation.sh` is a startup/management wrapper that:
- Starts/stops the manul daemon
- Installs/removes the `watchdog.sh` cron job
- Does NOT start `task-health-check.sh`
- Does NOT create duplicate recovery mechanisms

### config.json

```json
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "agents": [
    "architect",
    "coder",
    "coder-cheap",
    "coder-strong",
    "coder-expert",
    "reviewer",
    "reviewer-expert",
    "debugger",
    "debugger-expert",
    "researcher",
    "tester",
    "security",
    "performance",
    "refactorer"
  ],
  "autoCreatePr": true,
  "autoRebaseOnPrBase": true,
  "autoRebaseOnPrBaseNote": "For review comments, always sync work dir to pr_base_branch (the base of the PR the comment lives on) before checking out existing_branch. Prevents working on a stale/merged manul branch.",
  "allowedUsers": ["<GITHUB_LOGIN>"],
  "repositories": [
    "<owner>/<repo>",
    "<owner>/<repo>"
  ],
  "retryConfig": {
    "maxAttempts": 3,
    "contextStrategy": "progressive",
    "contextLimits": [240000, 120000, 60000],
    "useLightContextOnFinalRetry": true,
    "sessionTimeoutSeconds": 300
  },
  "compaction": {
    "retryOnTimeout": true,
    "fallbackCutoffTokens": 240000
  },
  "ciFix": {
    "enabled": true,
    "maxAttemptsPerRun": 2,
    "cooldownMinutes": 60
  },
  "automation": {
    "enabled": true,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900,
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800,
    "alerts": {
      "failureWebhook": null,
      "stuckTaskWebhook": null
    }
  }
}
```

* `automation` — heartbeat/lease settings and recovery thresholds
* `heartbeatTimeout` — seconds before a task is considered stale (default 900)
* `leaseTimeout` — total lease duration in seconds (default 900)
* `maxAttemptsBeforeFail` — mark as failed after N attempts (default 3)
* `lockTtl` — lock file TTL in seconds (default 1800)
* `alerts` — optional webhook configuration

### Troubleshooting

**Common Issue: "Unknown agent id 'manul'"**

This error occurs when the gateway cannot find the `manul` agent definition, typically because the agent is missing from the gateway configuration or the skill definition.

**Causes:**
1. **Missing agent** – The native OpenClaw agent `manul` is not registered with the gateway.
2. **Skill definition not present** – The canonical skill source (`~/.globalskills/skills/manul-github-bot/`) is missing or corrupted.
3. **Symlink broken** – The symlinks in `~/.openclaw/manul/` (e.g., `watchdog.sh`, `task-recovery.sh`, `orchestrator.prompt.md`) are broken.

**Diagnosis:**
- Verify the agent exists: `openclaw agents list`
- Check the agent workspace exists: `ls -la ~/.openclaw/manul-workspace`
- Verify the skill files are present in `~/.globalskills/skills/manul-github-bot/`.
- Ensure the symlinks in `~/.openclaw/manul/` are valid:
  ```bash
  ls -la ~/.openclaw/manul/watchdog.sh ~/.openclaw/manul/task-recovery.sh ~/.openclaw/manul/orchestrator.prompt.md
  ```

**Resolution:**
1. **Ensure the agent is registered** – Re-add the agent: `openclaw agents add manul --workspace ~/.openclaw/manul-workspace --model litellm/groq-llama-70b --non-interactive`
2. **Verify symlinks** – Recreate any broken symlinks:
    ```bash
    ln -sf ~/.globalskills/skills/manul-github-bot/watchdog.sh ~/.openclaw/manul/watchdog.sh
    ln -sf ~/.globalskills/skills/manul-github-bot/task-recovery.sh ~/.openclaw/manul/task-recovery.sh
    ln -sf ~/.globalskills/skills/manul-github-bot/orchestrator.prompt.md ~/.openclaw/manul/orchestrator.prompt.md
    ```
3. **Verify agent works** – Test the native agent: `openclaw agent --agent manul -m "Reply with exactly: MANUL_AGENT_OK" --json`

## Installation

Run the installer or use the skill directly. After installation:

1. Create the manul runtime directory and symlink skill files:
    ```bash
    mkdir -p /mnt/f/ubuntu-workspace/.openclaw/manul
    ln -sf ~/.globalskills/skills/manul-github-bot/poll.sh /mnt/f/ubuntu-workspace/.openclaw/manul/
    ln -sf ~/.globalskills/skills/manul-github-bot/orchestrator.prompt.md /mnt/f/ubuntu-workspace/.openclaw/manul/
    ln -sf ~/.globalskills/skills/manul-github-bot/manul-comments-remove.sh /mnt/f/ubuntu-workspace/.openclaw/manul/
    ln -sf ~/.globalskills/skills/manul-github-bot/github-api-wrapper.sh /mnt/f/ubuntu-workspace/.openclaw/manul/
    ln -sf ~/.globalskills/skills/manul-github-bot/watchdog.sh /mnt/f/ubuntu-workspace/.openclaw/manul/
    ln -sf ~/.globalskills/skills/manul-github-bot/task-recovery.sh /mnt/f/ubuntu-workspace/.openclaw/manul/
    ln -sf ~/.globalskills/skills/manul-github-bot/start-manul-automation.sh /mnt/f/ubuntu-workspace/.openclaw/manul/
    ln -sf ~/.globalskills/skills/manul-github-bot/manul-status.sh /mnt/f/ubuntu-workspace/.openclaw/manul/
    ```

2. Copy and customize the config:
    ```bash
    cp ~/.globalskills/skills/manul-github-bot/config.json.example /mnt/f/ubuntu-workspace/.openclaw/manul/config.json
    # then edit /mnt/f/ubuntu-workspace/.openclaw/manul/config.json with your repos, allowedUsers, etc.
    ```

3. Make scripts executable:
    ```bash
    chmod +x /mnt/f/ubuntu-workspace/.openclaw/manul/*.sh
    ```

4. Start the automation:
    ```bash
    /mnt/f/ubuntu-workspace/.openclaw/manul/start-manul-automation.sh install
    ```

```bash
alias manul-status='$OPENCLAW_MANUL_DIR/manul-status.sh'
alias manul-comments-remove='$OPENCLAW_MANUL_DIR/manul-comments-remove.sh'
```

**Files are symlinked, not copied:** `poll.sh`, `manul-comments-remove.sh`, `orchestrator.prompt.md`, `watchdog.sh`, `task-recovery.sh`, `start-manul-automation.sh`, and `manul-status.sh` in `/mnt/f/ubuntu-workspace/.openclaw/manul/` are symlinks pointing back to the canonical copies here. When the skill updates, the symlinked files refresh automatically — no copy step is needed.

To verify the symlinks are intact:

```bash
ls -la /mnt/f/ubuntu-workspace/.openclaw/manul/watchdog.sh /mnt/f/ubuntu-workspace/.openclaw/manul/task-recovery.sh /mnt/f/ubuntu-workspace/.openclaw/manul/start-manul-automation.sh /mnt/f/ubuntu-workspace/.openclaw/manul/manul-status.sh
```

If a symlink is ever broken (e.g. after manually editing the installed copy), recreate it:

```bash
ln -sf ~/.globalskills/skills/manul-github-bot/watchdog.sh /mnt/f/ubuntu-workspace/.openclaw/manul/watchdog.sh
ln -sf ~/.globalskills/skills/manul-github-bot/task-recovery.sh /mnt/f/ubuntu-workspace/.openclaw/manul/task-recovery.sh
ln -sf ~/.globalskills/skills/manul-github-bot/start-manul-automation.sh /mnt/f/ubuntu-workspace/.openclaw/manul/start-manul-automation.sh
ln -sf ~/.globalskills/skills/manul-github-bot/manul-status.sh /mnt/f/ubuntu-workspace/.openclaw/manul/manul-status.sh
```

### Manual Recovery

`task-recovery.sh` provides manual intervention tools:

```bash
# List stuck tasks
$MANUL_DIR/task-recovery.sh --list-stuck

# Reset a specific stuck task
$MANUL_DIR/task-recovery.sh --reset issue:5319953481

# Run health check
$MANUL_DIR/task-recovery.sh --health-check
```

### Related

- [Default AGENTS.md](/reference/AGENTS.default)
- [Scheduled tasks vs heartbeat](/automation#scheduled-tasks-cron-vs-heartbeat)
- [Heartbeat](/gateway/heartbeat)

Base directory for this skill: /home/marzec/.globalskills/skills/manul-github-bot
Relative paths in this skill (e.g., scripts/, reference/) are relative to this base directory.
Note: file list is sampled.
