---
name: manul-github-bot
description: Setup, operate, and reinstall the manul GitHub command bot (OpenClaw + gh). Manul reacts to `/manul` in issue/PR comments, implements the task on a `manul/*` branch, pushes, optionally opens a PR, and replies with comments signed "manul 🐈". Use when installing manul on a (new) machine, changing its config, or debugging it. This skill directory is the canonical source for `poll.sh`, `manul-comments-remove.sh`, `orchestrator.prompt.md`, and the **enhanced automation scripts** for task recovery, health monitoring, and proactive task management.
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
manul-daemon.sh (setsid background loop, no systemd needed)
   │ every pollInterval (default 60s)
   ▼
poll.sh ── gh api: issue bodies + issue comments + PR review comments
   │         (created_at >= baseline) + contains trigger
   ▼
SQLite manul.db (processed_comments: queued→running→done|failed, meta.baseline)
   │ rebuild queue.json
   ▼
fire:true? ──► openclaw agent --agent manul --message-file orchestrator.prompt.md \
                  --session-key manul-worker  (headless, timeout -k 60)
                        │
                        ▼
manul agent (isolated persona: /mnt/f/ubuntu-workspace/.openclaw/workspace-manul, restricted tools,
             own session store under /mnt/f/ubuntu-workspace/.openclaw/agents/manul/sessions)
   orchestrator: per task → mark running → post "🤖 Running..." →
                 sessions_spawn subagent (worker) → wait (sessions_yield)
                        │
                        ▼
worker: clone repo → branch <type>/manul/<issue>-<slug> → implement → tests → commit
        (Co-authored-by trailer) → push → gh pr create (if autoCreatePr)
                        │
                        ▼
orchestrator: parse MANUL_RESULT → post ✅ Done / ❌ Failed (English only)
              → update DB (done/failed)
```

Dispatch is synchronous (daemon waits for the agent turn), so runs never
overlap; `lock` is a backstop with 30 min TTL.

## Files (canonical source lives here — symlinked into `~/.openclaw/manul/`)

| Path | Purpose |
|---|---|
| `~/.globalskills/skills/manul-github-bot/SKILL.md` | skill/rules source of truth |
| `~/.globalskills/skills/manul-github-bot/poll.sh` | canonical poller script (symlinked into `~/.openclaw/manul/poll.sh`) |
| `~/.globalskills/skills/manul-github-bot/orchestrator.prompt.md` | canonical orchestrator prompt (symlinked into `~/.openclaw/manul/orchestrator.prompt.md`) |
| `~/.globalskills/skills/manul-github-bot/manul-comments-remove.sh` | comment cleanup script (symlinked) |
| **`~/.globalskills/skills/manul-github-bot/watchdog.sh`** | **enhanced watchdog script (symlinked into `~/.openclaw/manul/watchdog.sh`) — NEW 2026-08-25** |
| **`~/.globalskills/skills/manul-github-bot/task-recovery.sh`** | **task recovery CLI for manual intervention (symlinked into `~/.openclaw/manul/task-recovery.sh`) — NEW 2026-08-25** |
| **`~/.globalskills/skills/manul-github-bot/task-health-check.sh`** | **proactive task health monitor (symlinked into `~/.openclaw/manul/task-health-check.sh`) — NEW 2026-08-25** |
| **`~/.globalskills/skills/manul-github-bot/start-manul-automation.sh`** | **automation startup helper (symlinked into `~/.openclaw/manul/start-manul-automation.sh`) — NEW 2026-08-25** |
| `~/.globalskills/skills/manul-github-bot/config.json.example` | configuration template (copy to `~/.openclaw/manul/config.json` and customize) |

### Enhanced watchdog.sh (NEW 2026-08-25)

The enhanced watchdog provides **proactive task recovery** beyond the basic lock cleanup:

**New features:**
- Detects tasks stuck in 'running' for >15 minutes (configurable via `automation.maxTaskRunningTime`)
- Automatically resets tasks to 'queued' or marks them as 'failed' based on attempt count
- Logs all stuck task detections for debugging
- Optional webhook alerts for systemic failures
- Configurable timeouts and failure thresholds via config.json

**Key improvements over original:**
- **Task health monitoring** — catches stuck tasks before they block the queue
- **Configurable thresholds** — adjust max running time and max attempts via config
- **Failure detection** — alerts when multiple failures occur in short time
- **Better logging** — detailed logs for troubleshooting

**Installation:**
- Automatically installed when using `start-manul-automation.sh`
- Can be installed manually: `cp ~/.globalskills/skills/manul-github-bot/watchdog.sh ~/.openclaw/manul/watchdog.sh`

**Schedule:** Runs every 5 minutes via cron

### Task Recovery CLI (NEW 2026-08-25)

`task-recovery.sh` provides **manual intervention** capabilities for stuck manul tasks:

**Commands:**
- `--list-stuck` — List all tasks stuck in 'running' state
- `--reset <id>` — Reset a specific task commentId to 'queued'
- `--mark-failed <id>` — Mark a specific task commentId as 'failed'
- `--reset-all` — Reset ALL running tasks (requires confirmation)
- `--health-check` — Run comprehensive health check with recommendations

**Use cases:**
- Manually recover tasks stuck after orchestrator crashes
- Inspect task health and get recommendations
- Force-mark problematic tasks as failed
- Emergency queue cleanup

**Example usage:**
```bash
# List stuck tasks
~/.openclaw/manul/task-recovery.sh --list-stuck

# Reset a specific stuck task
~/.openclaw/manul/task-recovery.sh --reset issue:5319953481

# Run health check
~/.openclaw/manul/task-recovery.sh --health-check
```

### Task Health Monitor (NEW 2026-08-25)

`task-health-check.sh` runs as a **background service** and continuously monitors manul task state:

**Features:**
- Detects tasks stuck in 'running' for >15 minutes
- Automatically recovers stuck tasks based on attempt count
- Logs system status every run
- Can be run manually for diagnostics

**Schedule:** Runs every 2 minutes via cron

**Logs:** All activity written to `~/.openclaw/manul/task-health.log`

### Automation Startup Helper (NEW 2026-08-25)

`start-manul-automation.sh` provides **easy installation and management** of all enhanced manul components:

**Commands:**
- `install` — Install and configure everything (recommended)
- `start` — Start manul daemon
- `stop` — Stop manul daemon
- `status` — Show status of all components
- `restart` — Restart all components

**Installation benefits:**
- Sets up executable permissions for all scripts
- Installs config.json from template
- Configures cron jobs (watchdog every 5min, health check every 2min)
- Starts daemon and task health monitor
- Provides helpful status output

**Quick setup:**
```bash
~/.openclaw/manul/start-manul-automation.sh install
```

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
    "maxTaskRunningTime": 900,
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800,
    "taskHealthCheckInterval": 120,
    "alerts": {
      "failureWebhook": null,
      "stuckTaskWebhook": null
    }
  }
}
```

* `automation` — new section with settings for proactive task recovery and health monitoring
* `maxTaskRunningTime` — max seconds a task can stay 'running' before auto-recovery (default 15 minutes)
* `maxAttemptsBeforeFail` — auto-mark as failed after N attempts (default 3)
* `taskHealthCheckInterval` — seconds between health checks (default 120 seconds/2 minutes)

### Troubleshooting

**Common Issue: "Unknown agent id 'manul'"**

This error occurs when the gateway cannot find the `manul` agent definition, typically because the agent is missing from the gateway configuration or the skill definition.

**Causes:**
1. **Missing agent in `.agents.list`** – The gateway looks for agent definitions in `~/.agents/agents/` (symlinked to `~/.globalskills/skills/`). If the manul entry is absent, the gateway reports "Unknown agent id 'manul'".
2. **Skill definition not present** – The canonical skill source (`~/.globalskills/skills/manul-github-bot/`) is missing or corrupted.
3. **Symlink broken** – The symlinks in `~/.openclaw/manul/` (e.g., `watchdog.sh`, `task-recovery.sh`, `orchestrator.prompt.md`) are broken, preventing the gateway from loading the skill.

**Diagnosis:**
- Check that `~/.agents/agents/manul` exists and contains the correct agent definition (see `agent.yaml`).
- Verify the skill files are present in `~/.globalskills/skills/manul-github-bot/`.
- Ensure the symlinks in `~/.openclaw/manul/` are valid:
  ```bash
  ls -la ~/.openclaw/manul/watchdog.sh ~/.openclaw/manul/task-recovery.sh ~/.openclaw/manul/orchestrator.prompt.md
  ```

**Resolution:**
1. **Ensure the agent is registered** – Run `gateway config list` or `gateway get agents` to see if the manul agent appears. If not, add it to `~/.agents/agents/manul` (or regenerate via `start-manul-automation.sh install`).
2. **Restore the skill** – If the skill is missing, copy the entire skill directory back:
   ```bash
   cp -r ~/.globalskills/skills/manul-github-bot ~/.openclaw/agents/  # restore symlinks
   # Then run: ~/.openclaw/manul/start-manul-automation.sh install
   ```
3. **Verify symlinks** – Recreate any broken symlinks:
   ```bash
   ln -sf ~/.globalskills/skills/manul-github-bot/watchdog.sh ~/.openclaw/manul/watchdog.sh
   ln -sf ~/.globalskills/skills/manul-github-bot/task-recovery.sh ~/.openclaw/manul/task-recovery.sh
   ln -sf ~/.globalskills/skills/manul-github-bot/orchestrator.prompt.md ~/.openclaw/manul/orchestrator.prompt.md
   ```
4. **Reload the gateway** – After making changes, reload the gateway configuration:
   ```bash
   gateway restart
   ```

Once fixed, the "Unknown agent id 'manul'" error will disappear and the manul bot will function normally.

### Installation

Run the installer or use the skill directly. After installation:

1. Copy the config template and customize it:
   ```bash
   cp ~/.globalskills/skills/manul-github-bot/config.json.example ~/.openclaw/manul/config.json
   # then edit ~/.openclaw/manul/config.json with your repos, allowedUsers, etc.
   ```

2. Add a convenience alias for `manul-status` and `manul-comments-remove` in your shell rc:

```bash
alias manul-status='$HOME/.openclaw/manul/manul-status.sh'
alias manul-comments-remove='$HOME/.openclaw/manul/manul-comments-remove.sh'
```

**Files are symlinked, not copied:** `poll.sh`, `manul-comments-remove.sh`, `orchestrator.prompt.md`, `watchdog.sh`, `task-recovery.sh`, `task-health-check.sh`, and `start-manul-automation.sh` in `~/.openclaw/manul/` are symlinks pointing back to the canonical copies here. When the skill updates, the symlinked files refresh automatically — no copy step is needed.

To verify the symlinks are intact:

```bash
ls -la ~/.openclaw/manul/watchdog.sh ~/.openclaw/manul/task-recovery.sh ~/.openclaw/manul/task-health-check.sh ~/.openclaw/manul/start-manul-automation.sh
```

If a symlink is ever broken (e.g. after manually editing the installed copy), recreate it:

```bash
ln -sf ~/.globalskills/skills/manul-github-bot/watchdog.sh ~/.openclaw/manul/watchdog.sh
ln -sf ~/.globalskills/skills/manul-github-bot/task-recovery.sh ~/.openclaw/manul/task-recovery.sh
ln -sf ~/.globalskills/skills/manul-github-bot/task-health-check.sh ~/.openclaw/manul/task-health-check.sh
ln -sf ~/.globalskills/skills/manul-github-bot/start-manul-automation.sh ~/.openclaw/manul/start-manul-automation.sh
```

### Enhanced Automation Features (NEW 2026-08-25)

**Before:** Manul had a basic watchdog that only cleared stale locks every 5 minutes. Tasks stuck in 'running' state would remain stuck indefinitely, blocking the queue.

**After:** The enhanced automation provides **proactive task recovery**:

1. **Task Health Monitoring** (`task-health-check.sh`) — Runs every 2 minutes and detects tasks stuck in 'running' state for >15 minutes, automatically recovering them.

2. **Enhanced Watchdog** (`watchdog.sh`) — Builds on original watchdog with:
   - Proactive task recovery (same as task-health-check.sh)
   - System-wide health checks
   - Webhook alerts for systemic issues
   - Better error handling

3. **Task Recovery CLI** (`task-recovery.sh`) — Manual intervention tools for debugging and emergency recovery.

4. **Automation Startup Helper** (`start-manul-automation.sh`) — One-command installation and management.

**Example emergency recovery:**
```bash
# If tasks are getting stuck
~/.openclaw/manul/task-recovery.sh --list-stuck
~/.openclaw/manul/task-recovery.sh --reset-all  # Requires confirmation

# Or run health check
~/.openclaw/manul/task-recovery.sh --health-check
```

### Related

- [Default AGENTS.md](/reference/AGENTS.default)
- [Scheduled tasks vs heartbeat](/automation#scheduled-tasks-cron-vs-heartbeat)
- [Heartbeat](/gateway/heartbeat)