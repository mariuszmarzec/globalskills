# Manul GitHub Control Protocol

Machine-readable protocol for external orchestrators (e.g., ChatGPT) to communicate with Manul via GitHub Issues and PRs.

## Overview

This protocol enables AI agents to:
- Create tasks via Issue comments
- Provide PR review feedback that creates fix tasks
- Receive structured results via HTML event markers
- Maintain conversation context across Issue ↔ PR relationships

## Command Grammar

Issue/PR comments starting with `/manul` are parsed as commands:

| Command | Action | Description |
|---------|--------|-------------|
| `/manul run <task>` | `IMPLEMENT` | Create implementation task |
| `/manul review-fix <prompt>` | `REVIEW_FIX` | Create task to address PR review comments |
| `/manul continue` | `CONTINUE` | Continue previous task |
| `/manul verify <prompt>` | `VERIFY` | Create verification task |
| `/manul status` | `STATUS` | Get current task status |
| `/manul close` | `CLOSE` | Close conversation |

## Event Format

Machine-readable events are posted as HTML comments:

```html
<!-- manul:event {"type":"TASK_DONE","timestamp":"2026-09-11T18:00:00Z","data":{"taskId":"t-1","status":"completed","prNumber":100}} -->
```

### Event Types

| Type | Direction | Description |
|------|-----------|-------------|
| `TASK_STARTED` | Bot → GitHub | Task execution began |
| `TASK_DONE` | Bot → GitHub | Task completed successfully |
| `TASK_FAILED` | Bot → GitHub | Task failed after all attempts |
| `REVIEW_APPROVED` | Bot → GitHub | PR review approved |
| `REVIEW_REQUESTED` | Orchestrator → Bot | Review feedback to address |

### Event Schema

```json
{
  "type": "TASK_DONE",
  "timestamp": "2026-09-11T18:00:00Z",
  "data": {
    "taskId": "string",
    "conversationId": "string",
    "prNumber": number,
    "status": "completed|failed",
    "attempt": number,
    "summary": "string"
  }
}
```

## Conversation Lifecycle

### Issue-Based Workflow

```
User opens Issue → /manul comment → Task created → Bot works → Result posted
```

- Issue number ↔ `conversationId` (one-to-one)
- Multiple comments on same Issue share conversation
- PR created from Issue automatically linked

### PR Review Workflow

```
PR opened → Orchestrator reviews → /manul review-fix → Task created → Fix committed → PR updated
```

- PR ↔ `conversationId` (many-to-one)
- Review states mapped to actions:
  - `APPROVE` → No task created
  - `REQUEST_CHANGES` → `REVIEW_FIX` task created on same PR
  - `COMMENT` → Informational only
  - `DISMISS` → No task created

## Database Schema

### processed_comments

```sql
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  author TEXT,
  prompt TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  conversationId TEXT,
  parentTaskId TEXT,
  action TEXT DEFAULT 'IMPLEMENT',
  prNumber INTEGER,
  prUrl TEXT,
  resultSummary TEXT,
  resultJson TEXT
);
```

### conversations

```sql
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER,
  issueUrl TEXT,
  activePrNumber INTEGER,
  activePrUrl TEXT,
  status TEXT NOT NULL DEFAULT 'OPEN',
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
```

### conversation_links

```sql
CREATE TABLE conversation_links (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversationId TEXT NOT NULL,
  repo TEXT NOT NULL,
  issueNumber INTEGER,
  prNumber INTEGER,
  commentId TEXT,
  taskCommentId TEXT,
  linkType TEXT NOT NULL,
  createdAt TEXT NOT NULL
);
```

## Security Considerations

- All user inputs are SQL-escaped via `sql_escape()` function
- HTML comments use `<!-- manul:event ... -->` format to avoid code injection
- Orchestrator commands require `/manul` prefix
- Duplicate processing prevented via `commentId` primary key

## Scripts

| Script | Purpose |
|--------|---------|
| `manul-github-events.sh` | Parse comments/reviews, extract commands, post events |
| `manul-pr-review.sh` | Handle PR review events, create fix tasks |
| `manul-conversation-linker.sh` | Link Issues ↔ PRs ↔ Tasks |
| `manul-result-feedback.sh` | Post task results back to GitHub |

## Testing

Run the full test suite:

```bash
bash skills/manul-github-bot/test_github_control_protocol.sh
```

Tests cover:
- Issue command parsing
- Conversation preservation
- Duplicate detection
- PR review handling
- Event extraction/validation
- Result feedback
- End-to-end workflow

## Integration with Existing Manul

The protocol integrates with existing Manul components:

1. **poll.sh** → Calls `manul-github-events.sh parse-comment` for GitHub comments
2. **manul-daemon.sh** → Receives tasks with `conversationId`, `parentTaskId`, `prNumber`
3. **manul-result.sh** → Calls `manul-result-feedback.sh post-done` to post results
4. **manul-conversation.sh** → Manages conversation lifecycle

## Migration Notes

- Existing Issue comments without `/manul` prefix are ignored
- New `conversationId` format: `conv-{repo}-{issue}`
- Existing tasks continue to work; new fields are optional
