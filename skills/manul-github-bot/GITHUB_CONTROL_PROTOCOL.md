# Manul GitHub Control Protocol

Machine-readable protocol for external orchestrators and agents to communicate with Manul through GitHub Issues and Pull Requests.

## Overview

The protocol provides:

- command submission through `/manul` comments;
- review-driven fix tasks;
- user-input continuation;
- structured lifecycle/result events;
- Issue ↔ PR ↔ task conversation linking.

## Command grammar

Issue/PR comments beginning with `/manul` are parsed as:

| Command | Action | Description |
|---|---|---|
| `/manul run <task>` | `IMPLEMENT` | Submit an implementation task |
| `/manul run --agent <agent> <task>` | `IMPLEMENT` | Submit with a specific configured agent |
| `/manul review-fix <prompt>` | `REVIEW_FIX` | Create a task for PR review feedback |
| `/manul continue <answer>` | `CONTINUE` | Resume a task blocked on user input |
| `/manul verify <prompt>` | `VERIFY` | Create a verification task |
| `/manul status` | `STATUS` | Query conversation status |
| `/manul close` | `CLOSE` | Close a conversation |

## Event format

Structured events are posted as HTML comments:

```html
<!-- manul:event {"type":"TASK_DONE","timestamp":"2026-09-11T18:00:00Z","data":{"taskId":"t-1","conversationId":"conv-1","status":"completed","prNumber":100,"attempt":1}} -->
```

### Event types

| Type | Direction | Meaning |
|---|---|---|
| `TASK_STARTED` | Bot → GitHub | Execution began |
| `TASK_NEEDS_USER` | Bot → GitHub | Task is waiting for user input |
| `TASK_DONE` | Bot → GitHub | Task completed |
| `TASK_FAILED` | Bot → GitHub | Task failed after retry policy |
| `REVIEW_APPROVED` | Bot → GitHub | Review approved |
| `REVIEW_REQUESTED` | Orchestrator → Bot | Review feedback to address |

The result-comment marker is a separate deterministic correlation mechanism:

`<!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->`

The daemon requires that marker when accepting an agent `TASK_DONE`.

## User-input semantics

An implementation agent may request user input only when a material decision cannot be resolved from repository context, documentation, skills, or established conventions.

When input is required:

1. the agent emits a `TASK_NEEDS_USER_BEGIN` / `TASK_NEEDS_USER_END` block;
2. Manul records `blocked_user`;
3. the question is posted to the same GitHub conversation;
4. the original task/conversation context is retained;
5. `/manul continue <answer>` resumes the task.

`blocked_user` is not a failure and does not consume another execution attempt until resumed.

## Conversation lifecycle

### Issue workflow

```
Issue -> /manul command -> task -> execution -> result
```

An issue is associated with a conversation ID. Multiple tasks may belong to the same conversation.

### PR review workflow

```
PR review -> /manul review-fix -> REVIEW_FIX task -> same PR branch -> updated PR
```

Review handling:

- `APPROVE` -> record approval, no fix task;
- `REQUEST_CHANGES` -> create `REVIEW_FIX`;
- `COMMENT` -> informational review event;
- `DISMISS` -> no fix task.

## Database schema

The following describes the effective logical schema used by the current Manul scripts. Individual schema initializers may create a subset and add columns incrementally.

### processed_comments

```sql
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  author TEXT,
  agent TEXT,
  prompt TEXT NOT NULL,
  context TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  claimToken TEXT,
  nextAttemptAt TEXT,
  conversationId TEXT,
  parentTaskId TEXT,
  workspaceId TEXT,
  action TEXT DEFAULT 'IMPLEMENT',
  prNumber INTEGER,
  prUrl TEXT,
  resultSummary TEXT,
  resultJson TEXT,
  baseId TEXT,
  taskId TEXT
);
```

Important execution fields:

- `attempts` — actual claims only;
- `heartbeatAt` / `leaseExpiresAt` — liveness;
- `workerPid` / `claimToken` — ownership;
- `conversationId` / `parentTaskId` — task graph/context;
- `workspaceId` — isolated workspace assignment;
- `resultSummary` / `resultJson` — result data;
- `baseId` — idempotency/deduplication support;
- `taskId` — review/orchestrator task association where present.

### conversations

```sql
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER,
  issueUrl TEXT,
  activeTaskId TEXT,
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
  createdAt TEXT NOT NULL,
  FOREIGN KEY (conversationId) REFERENCES conversations(conversationId)
);
```

SQLite is the source of truth for Manul task state.

## Security and integrity

- User inputs are SQL-escaped before SQL construction.
- Command parsing requires the `/manul` prefix.
- `commentId` and related idempotency mechanisms prevent duplicate event processing.
- Task/attempt markers prevent stale result comments from satisfying a later retry.
- Worker ownership checks prevent one worker from finalizing another worker's task.

## Result and PR verification

Repository-change tasks must:

- commit on a non-base task branch;
- push the branch;
- create/verify a concrete PR;
- report the verified PR URL.

The daemon may create a missing PR when `autoCreatePr` is enabled, but a `TASK_DONE` is still not accepted without verified PR identity.

Never treat `/compare` or `/pull/new` URLs as proof of a PR.

## Current runtime boundary

Current master executes the agent through OpenClaw.

The filesystem location of Manul's current runtime is an implementation detail. The approved next architecture moves Manul-owned state to `~/.manul` and hides runtime-specific execution behind `AgentExecutor`.

## Testing

Protocol tests:

```bash
bash skills/manul-github-bot/test_github_control_protocol.sh
bash skills/manul-github-bot/test_github_control_integration.sh
```

For behavioural changes, also run the relevant daemon/concurrency/review workflow tests.
