# Manul Local Task Interface

Local machine-readable task queue interface for external clients (e.g., ChatGPT orchestrator) to interact with the Manul task system via SQLite.

## Overview

This interface provides four CLI commands that allow external processes to:
- Submit tasks to the Manul queue
- Query task status
- Retrieve structured results
- Wait for task completion

The interface operates on the same SQLite database (`~/.openclaw/manul/manul.db`) as the GitHub-based workflow, ensuring full backward compatibility.

## Commands

### `manul-submit.sh` - Submit a task

```bash
manul-submit.sh [OPTIONS]

Options:
  --repo REPO          Repository (required, format: owner/repo)
  --issue ISSUE        Issue or PR number (required)
  --comment URL        Comment URL for conversation grouping (optional)
  --prompt TEXT        Task prompt (required, or read from stdin)
  --conversation ID    Conversation ID for grouping (optional)
  --parent TASK_ID     Parent task ID for subtasks (optional)
  --agent AGENT        Agent name (optional, defaults to "main")
  --json               Output JSON format

Examples:
  manul-submit.sh --repo owner/repo --issue 1 --prompt "Fix bug"
  echo "Fix bug" | manul-submit.sh --repo owner/repo --issue 1
  manul-submit.sh --repo owner/repo --issue 1 --comment "https://github.com/..." --prompt "Reply to this" --json
```

**Output (JSON):**
```json
{
  "commentId": "cli-abc123...",
  "conversationId": "conv-xyz789",
  "status": "queued",
  "repo": "owner/repo",
  "issue": 1
}
```

**Idempotency:** Submissions with the same `--repo`, `--issue`, `--comment`, and `--prompt` return the same task ID (if task is still queued). The idempotency key is derived from `repo + issue + comment URL + prompt` using MD5 hash. To submit a duplicate task after completion/failure, use a different prompt or add a unique suffix.

---

### `manul-status.sh` - Query task status

```bash
manul-status.sh [OPTIONS] [TASK_ID]

Options:
  --task ID        Task/comment ID to query (required if no positional arg)
  --json           Output JSON format
  --list           List all tasks (optional filter by status)
  --status S       Filter by status (queued, running, completed, failed)
```

**Single task output:**
```json
{
  "taskId": "cli-abc123",
  "conversationId": "conv-xyz789",
  "status": "queued",
  "repo": "owner/repo",
  "issue": 1,
  "attempts": 0,
  "createdAt": "2024-01-01T00:00:00",
  "startedAt": null,
  "workerId": null,
  "workspaceId": null,
  "nextAttemptAt": null,
  "prompt": "Fix bug"
}
```

**List output:**
```json
[
  {"taskId": "...", "repo": "...", "issue": 1, "status": "queued", ...},
  ...
]
```

---

### `manul-result.sh` - Retrieve task result

```bash
manul-result.sh [OPTIONS] TASK_ID

Options:
  --json    Output JSON format
```

**Output:**
```json
{
  "taskId": "cli-abc123",
  "conversationId": "conv-xyz789",
  "status": "completed",
  "success": true,
  "summary": "Fixed the bug by updating config.yaml",
  "changedFiles": null,
  "commit": null,
  "pullRequest": null,
  "completedAt": "2024-01-01T00:05:00",
  "attempts": 1
}
```

For failed tasks:
```json
{
  "taskId": "cli-abc123",
  "status": "failed",
  "success": false,
  "error": "Could not connect to database",
  "completedAt": "2024-01-01T00:05:00",
  "attempts": 3
}
```

---

### `manul-wait.sh` - Wait for task completion

```bash
manul-wait.sh [OPTIONS] TASK_ID

Options:
  --timeout SECONDS  Maximum time to wait (default: 300)
  --interval SECONDS Polling interval (default: 5)
  --json             Output JSON format
  --follow           Print status updates as they happen
```

**Examples:**
```bash
manul-wait.sh cli-abc123
manul-wait.sh --timeout 600 --json cli-abc123
manul-wait.sh --follow cli-abc123
```

---

## Architecture

```
┌─────────────────┐     manul-submit.sh      ┌──────────────┐
│ External Client │ ────────────────────────► │  SQLite DB   │
└─────────────────┘                           └──────┬───────┘
                                                      │
                                                      ▼
┌─────────────────┐     manul-result.sh              ┌──────────────┐
│ External Client │ ◄────────────────────────  │  manul-daemon.sh │
└─────────────────┘                              └──────────────┘
                                                      │
                                                      ▼
                                               GitHub Comments
                                               (existing workflow)
```

## Database Schema

New columns added to `processed_comments`:
- `resultSummary TEXT` — Human-readable summary of task result
- `resultJson TEXT` — Structured JSON result data

## Backward Compatibility

- All existing GitHub `/manul` workflow behavior is unchanged
- The daemon automatically saves results when tasks complete
- No production database modifications are required
- Existing tests continue to pass

## Testing

Run the comprehensive test suite:
```bash
# CLI interface tests
bash skills/manul-github-bot/test_manul_cli.sh

# Full concurrency test suite (includes CLI tests K, L, M)
bash skills/manul-github-bot/test_concurrency.sh
```

## Integration Example

```bash
# Python-like pseudo-code for external orchestrator
import subprocess, json, time

def submit_task(repo, issue, prompt):
    result = subprocess.run([
        'manul-submit.sh',
        '--repo', repo,
        '--issue', str(issue),
        '--prompt', prompt,
        '--json'
    ], capture_output=True, text=True)
    return json.loads(result.stdout)

def wait_for_task(task_id, timeout=300):
    result = subprocess.run([
        'manul-wait.sh',
        '--timeout', str(timeout),
        '--json',
        task_id
    ], capture_output=True, text=True)
    return json.loads(result.stdout)

# Usage
task = submit_task('owner/repo', 1, 'Fix the login bug')
print(f"Submitted: {task['commentId']}")
result = wait_for_task(task['commentId'])
print(f"Success: {result['success']}")
```
