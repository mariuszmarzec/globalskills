# Manul Local Task Interface

Local machine-readable CLI interface for submitting, observing, and controlling Manul tasks.

## Runtime location

Current master reads the Manul runtime from:

```
${MANUL_DIR:-$HOME/.openclaw/manul}
```

Therefore the current default DB is:

```
~/.openclaw/manul/manul.db
```

This filesystem location is **not** a behavioural contract. The next runtime-isolation refactor intentionally moves Manul-owned state to `~/.manul` without requiring migration of old state.

## Submit a task

### `manul-submit.sh`

```bash
manul-submit.sh --repo OWNER/REPO --issue NUMBER --prompt "Task"
```

Options:

```
--repo REPO
--issue ISSUE
--comment URL
--prompt TEXT
--conversation ID
--parent TASK_ID
--agent AGENT
--json
```

The default agent argument is `main` in the current implementation.

JSON success output contains:

```json
{
  "commentId": "cli-...",
  "conversationId": "conv-...",
  "status": "queued",
  "repo": "owner/repo",
  "issue": 1
}
```

### Idempotency

Submissions use a base identity derived from:

```
repo + issue + comment URL + prompt
```

Duplicate submission claims are serialized in SQLite. A queued duplicate reuses the existing logical task rather than creating another execution.

## Status

### `manul-status.sh`

```bash
manul-status.sh --status STATUS
manul-status.sh --task TASK_ID
manul-status.sh --list
manul-status.sh --history
manul-status.sh --log --tail 200
```

Supported task-status filters include:

```
queued
running
blocked_user
completed
failed
stale
```

`--list` includes active tasks and recent terminal history. `--history` uses the longer configured retention window.

Example JSON shape:

```json
{
  "taskId": "cli-...",
  "conversationId": "conv-...",
  "status": "running",
  "repo": "owner/repo",
  "issue": 1,
  "attempts": 1
}
```

## Result

### `manul-result.sh`

```bash
manul-result.sh TASK_ID
manul-result.sh --json TASK_ID
```

This command returns results for terminal states:

```
completed
failed
```

Detailed repository results such as changed files, commits, and PRs are also reflected in the GitHub result comment and structured result data when available.

## Wait

### `manul-wait.sh`

```bash
manul-wait.sh TASK_ID
manul-wait.sh --timeout 600 --json TASK_ID
manul-wait.sh --follow TASK_ID
```

Options include:

```
--timeout SECONDS
--interval SECONDS
--json
--follow
```

`blocked_user` is surfaced as a resumable waiting state. Answer on GitHub with:

```
/manul continue <answer>
```

## Conversation

### `manul-conversation.sh`

Provides local commands for:

- create;
- submit;
- status;
- result;
- review;
- fix;
- close;
- DB schema initialization.

Its state is persisted in the Manul SQLite database.

## External orchestrator

### `manul-orchestrator.sh`

This is a higher-level state-machine wrapper around the local Manul task interface. Its own orchestration state is kept in `orchestrator.db` and is documented separately in `ORCHESTRATOR.md`.

## Manual task recovery

### `task-recovery.sh`

Typical manual commands:

```bash
task-recovery.sh --list-stuck
task-recovery.sh --reset TASK_ID
task-recovery.sh --mark-failed TASK_ID
task-recovery.sh --reset-all
task-recovery.sh --reset-all=running
task-recovery.sh --reset-all=failed
task-recovery.sh --retry TASK_ID
```

Manual recovery is for operator intervention. Normal stale recovery is handled by the daemon/watchdog mechanisms.

## Architecture

```
External caller
     |
     v
local CLI
     |
     v
SQLite manul.db
     |
     v
manul-daemon.sh
     |
     v
agent runtime
     |
     v
GitHub result / PR
```

## Testing

CLI-focused:

```bash
bash skills/manul-github-bot/test_manul_cli.sh
```

Shared state/concurrency changes should additionally run the relevant concurrency and workflow tests.

## Important boundary

Do not treat the current `~/.openclaw/manul/manul.db` path as an external API contract.

The approved architecture moves the same logical Manul interface to a dedicated `~/.manul` runtime root. No fallback to the old OpenClaw-owned path is required for that refactor.
