# Manul External Orchestrator

## Overview

The Manul external orchestrator is a local control layer that drives the Manul conversation/task system end-to-end via CLI.

## Architecture

```
external caller
      |
      v
manul-orchestrator.sh
      |
      +---- manul-conversation.sh
      +---- manul-submit.sh
      +---- manul-status.sh
      +---- manul-result.sh
      +---- manul-wait.sh
      |
      v
   Manul / SQLite
      |
      v
   GitHub
```

## State Machine

```
NEW → SUBMITTING → RUNNING → PR_READY → REVIEWING → APPROVED → COMPLETE
                                                     |
                                                     +→ CHANGES → FIXING → RUNNING → PR_READY
```

## CLI Commands

### `create`
```bash
manul-orchestrator.sh create --repo REPO --title TITLE --prompt PROMPT [--json] [--dry-run]
```

### `submit`
```bash
manul-orchestrator.sh submit --conversation-id ID --prompt PROMPT --action ACTION [--pr-number N] [--parent-task-id ID] [--json] [--dry-run]
```

### `wait`
```bash
manul-orchestrator.sh wait --task-id ID [--timeout SECONDS] [--json]
```

### `status`
```bash
manul-orchestrator.sh status --conversation-id ID [--json]
```

### `result`
```bash
manul-orchestrator.sh result --task-id ID [--json]
```

### `review`
```bash
manul-orchestrator.sh review --task-id ID --decision APPROVE|REQUEST_CHANGES|COMMENT|BLOCKED [--json]
```

### `fix`
```bash
manul-orchestrator.sh fix --conversation-id ID --prompt PROMPT --task-id PARENT_ID [--pr-number N] [--json] [--dry-run]
```

### `run`
```bash
manul-orchestrator.sh run --repo REPO --title TITLE --prompt PROMPT [--max-review-cycles N] [--json] [--dry-run]
```

### `close`
```bash
manul-orchestrator.sh close --conversation-id ID [--json]
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Generic failure |
| 2 | Not found |
| 3 | Bad request |
| 4 | Timeout |

## Files

- `manul-orchestrator.sh` - Main orchestrator entry point
- `orchestrator-reviewer.sh` - Pluggable reviewer interface
- `orchestrator-github.sh` - GitHub integration helpers
- `test_orchestrator.sh` - Comprehensive test suite
