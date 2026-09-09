---
name: manul-github-bot
description: Setup, operate, and reinstall the manul GitHub command bot (OpenClaw + gh). Manul reacts to `/manul` in issue/PR comments, implements the task on a `manul/*` branch, pushes, optionally opens a PR, and replies with comments signed "manul 🐈". Use when installing manul on a (new) machine, changing its config, or debugging it. This skill directory is the canonical source for all Manul executable scripts. Runtime scripts are symlinked from this directory into `/mnt/f/ubuntu-workspace/.openclaw/manul/`.
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

## GitHub Task Workflow

When executing a GitHub issue task, manul **must never modify the repository default branch directly**. The mandatory workflow is:

1. **Create a dedicated task branch** from the default branch before making any repository changes.
2. **Make all task commits on that task branch** — never on `master`, `main`, or any other default branch.
3. **Push the task branch** to GitHub.
4. **Deliver completed repository changes through a GitHub PR** targeting the default branch.
5. **Do not report a task as successfully completed** if the required PR could not be created.
6. The **default branch must remain untouched** by issue-task execution.

## Automated GitHub Comment Signature

Every comment or PR review comment that manul posts must include the signature:

```
— manul 🐈
```

Rules for the signature:

* The signature **must be separated from the comment body by two newlines**.
* **Do not append a duplicate signature** if the comment already ends with `— manul 🐈`.
* A signature occurring in the **middle** of the body does **not** prevent appending the final signature.

```
        /\_/\
       ( o.o )   manul 🐈 — GitHub command bot
        > ^ <
```

## Runtime Layout

Manul uses a **two-directory layout**:

| Directory | Contents | Notes |
|---|---|---|
| `~/.globalskills/skills/manul-github-bot/` | **Canonical source** — all scripts, prompts, docs | Single source of truth for executable code |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/` | **Runtime** — scripts (via symlinks) + data | Scripts are symlinks; data is local copies |

**Why this split?** The runtime directory lives on `/mnt/f` (Windows WSL2 mount) because:
- Repository worktrees and large Git operations are faster on the mounted filesystem
- The workspace (`workspace/`) contains cloned repositories that need to persist across reboots
- Logs and database remain accessible to both WSL2 and native Linux paths

**Scripts are symlinked, not copied:** Changes to canonical scripts are immediately reflected at runtime.

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
| `manul-daemon.sh` | consumes queued tasks, posts lifecycle/status comments, manages orchestrator execution |
| `watchdog.sh` | ONLY automatic recovery/liveness mechanism (daemon liveness, stale lock removal, heartbeat/lease-based task recovery) |
| `task-recovery.sh` | manual/admin recovery tool only (NOT automatic) |
| `task-health-check.sh` | LEGACY/DEPRECATED; MUST NOT be part of automatic operation |

**Agent Comment Posting Contract:**

Previously, the agent posted nothing to GitHub — the daemon extracted agent output from stdout and posted the result. **Under the new contract, the agent MUST post its own user-facing GitHub comment directly before `TASK_DONE`.**

- **Agent responsibility:** After completing the task, post a GitHub comment with the result.
- **Comment format:** Follow the existing automated GitHub comment signature rules (see "Automated GitHub Comment Signature" section). Include the signature `— manul 🐈` separated by two newlines.
- **Comment timing:** Post exactly one comment per task (the final result), **before** emitting `TASK_DONE`.
- **Comment routing:** Same as existing manul comment routing (top-level for issue/PR comments, in-thread reply for PR review comments).
- **Daemon behavior:** The daemon no longer extracts `AGENT_RESPONSE` from agent stdout. The agent comment is the source of truth for user-facing results.
- **Lifecycle comments:** The daemon continues to post lifecycle/status comments (`🔄 working`, `✅ completed`, `❌ failed`) on its own responsibility.
- **No comment posting rules:** The orchestrator prompt no longer restricts agents from posting GitHub comments — posting a result comment is now required.

**Result Comment Marker (deterministic task/attempt correlation):**

Every agent result comment MUST include an invisible HTML comment marker that identifies the exact task execution attempt:

```
<!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->
```

Where:
- `<COMMENT_ID>` is the task's `commentId` from the database (e.g. `5599133859`)
- `<ATTEMPT>` is the current attempt number (1-based, incremented on each claim)

This marker enables the daemon to verify that the result comment belongs to the exact task+attempt, preventing:
- Cross-contamination between retry attempts
- False matches from lifecycle comments (which share the `— manul 🐈` signature)
- Stale results from previous attempts satisfying current verification

The daemon rejects any comment lacking this marker, including lifecycle comments (`🔄`, `✅`, `❌`, `⚠️`) which carry the same author and signature but no marker.

**Dispatch is synchronous (daemon waits for the agent turn), so runs never
overlap; `lock` is a backstop with 30 min TTL.**

**Manul depends on OpenClaw `main` agent for task execution.** The daemon invokes `openclaw agent --agent main` to process tasks.

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
| `~/.globalskills/skills/manul-github-bot/manul-comments-remove.sh` | comment cleanup script (symlinked, supports both PR and issue URLs) |
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

This error occurs when the OpenClaw gateway cannot find the agent definition. Manul delegates to the **`main`** agent (not a separate `manul` agent).

**Causes:**
1. **Agent not registered** – The `main` agent is not registered with the gateway.
2. **Gateway not running** – OpenClaw gateway service is stopped.
3. **Config mismatch** – Gateway configuration does not match expected paths.

**Diagnosis:**
- Verify the agent exists: `openclaw agents list`
- Check gateway is running: `openclaw gateway status`
- Verify canonical files exist: `ls -la ~/.globalskills/skills/manul-github-bot/`
- Check symlinks are valid:
  ```bash
  ls -la /mnt/f/ubuntu-workspace/.openclaw/manul/*.sh
  ```

**Resolution:**
1. **Verify agent registration** – The `main` agent should be registered:
   ```bash
   openclaw agents list
   ```
2. **Verify symlinks** – Ensure runtime scripts are symlinked:
   ```bash
   ln -sf ~/.globalskills/skills/manul-github-bot/watchdog.sh /mnt/f/ubuntu-workspace/.openclaw/manul/watchdog.sh
   ln -sf ~/.globalskills/skills/manul-github-bot/task-recovery.sh /mnt/f/ubuntu-workspace/.openclaw/manul/task-recovery.sh
   ln -sf ~/.globalskills/skills/manul-github-bot/start-manul-automation.sh /mnt/f/ubuntu-workspace/.openclaw/manul/start-manul-automation.sh
   ```
3. **Test agent** – Verify the main agent works:
   ```bash
   openclaw agent --agent main -m "Reply with exactly: MAIN_AGENT_OK" --json
   ```

**Common Issue: Daemon not polling**

Check daemon status and logs:
```bash
# Check if daemon is running
cat /mnt/f/ubuntu-workspace/.openclaw/manul/daemon.pid
ps -p $(cat /mnt/f/ubuntu-workspace/.openclaw/manul/daemon.pid)

# Check recent logs
tail -50 /mnt/f/ubuntu-workspace/.openclaw/manul/daemon.log
```

**Common Issue: Watchdog not starting daemon**

The watchdog runs via cron (`*/5 * * * *`). Verify cron is installed:
```bash
crontab -l | grep watchdog
```

If missing, run:
```bash
/mnt/f/ubuntu-workspace/.openclaw/manul/start-manul-automation.sh start
```

## Installation

Run the installer or use the skill directly. After installation:

1. **Create runtime directory and deploy symlinks:**
   ```bash
   # Use the automated installer (recommended)
   ~/.globalskills/skills/manul-github-bot/install-manul-symlinks.sh
   
   # Or manually:
   mkdir -p /mnt/f/ubuntu-workspace/.openclaw/manul
   
   for script in manul-daemon.sh poll.sh watchdog.sh task-recovery.sh \
                 start-manul-automation.sh manul-status.sh \
                 manul-comments-remove.sh github-api-wrapper.sh; do
     ln -sf ~/.globalskills/skills/manul-github-bot/$script \
            /mnt/f/ubuntu-workspace/.openclaw/manul/$script
   done
   ```

2. **Copy and customize the config:**
   ```bash
   cp ~/.globalskills/skills/manul-github-bot/config.json.example \
      /mnt/f/ubuntu-workspace/.openclaw/manul/config.json
   # then edit /mnt/f/ubuntu-workspace/.openclaw/manul/config.json with your repos, allowedUsers, etc.
   ```

3. **Start the automation:**
   ```bash
   /mnt/f/ubuntu-workspace/.openclaw/manul/start-manul-automation.sh start
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
