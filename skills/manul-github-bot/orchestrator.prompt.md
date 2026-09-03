# Updated Manul Orchestrator with Heartbeat/Lease System

## Overview
The orchestrator implements a heartbeat/lease-based task management system that ensures proper task recovery and prevents duplicate execution.

## Task Lifecycle with Heartbeat

### State Transitions

```
queued → running (with heartbeat lease)
running → done (task completed successfully)
running → failed (task failed permanently)
running → queued (task crashed/stuck, has attempts remaining)
```

### Detailed State Rules

#### 1. Queued → Running
When a task is claimed by the orchestrator:
- Atomic transition using SQL UPDATE with WHERE status='queued'
- Attempts count increments by 1 (atomic)
- Set processedAt = startedAt = heartbeatAt = current timestamp
- Set workerPid = current worker ID (if available)
- Set leaseExpiresAt = heartbeatAt + leaseTimeout

```sql
UPDATE processed_comments
SET status='running',
    attempts=attempts+1,
    processedAt=datetime('now'),
    heartbeatAt=datetime('now'),
    startedAt=datetime('now'),
    workerPid='<worker-id>',
    leaseExpiresAt=datetime('now', '+<lease-timeout>')
WHERE commentId='<commentId>'
  AND status='queued';
```

#### 2. Running → Done
Task completed successfully:
- No heartbeat updates required
- Mark as done with processedAt set
- Keep heartbeatAt for audit trail

#### 3. Running → Failed (orchestrator decision)
Task failed after all attempts:
- Set status='failed'
- Do NOT increment attempts (failure doesn't count as an attempt)
- Clear timestamps

#### 4. Running → Queued (recovery)
Task crashed/stuck (detected by stale heartbeat):
- Set status='queued'
- Do NOT increment attempts (recovery doesn't count as an attempt)
- Clear processedAt, heartbeatAt, workerPid, leaseExpiresAt

## Heartbeat Mechanism

### Worker Heartbeat
The worker periodically updates heartbeat to indicate it's alive:

```bash
# In worker script (every heartbeatInterval seconds)
sqlite3 "$MANUL_DIR/manul.db" "
  UPDATE processed_comments
  SET heartbeatAt=datetime('now'),
      leaseExpiresAt=datetime('now', '+<lease-timeout>')
  WHERE commentId='<commentId>'
    AND status='running'
    AND workerPid='<worker-id>';
"
```

### Lease Semantics
- Lease expires after heartbeatTimeout seconds
- Stale heartbeat (> heartbeatTimeout) triggers recovery
- Lease protects against race conditions during task execution

### Recovery Logic (Watchdog.sh)

Watchdog runs every 5 minutes and:

1. **Daemon Liveness**: Check if daemon process is running
2. **Stale Lock**: Detect and remove stale daemon lock file
3. **Task Recovery**: For each running task:
   - Calculate age = now - heartbeatAt
   - If age > heartbeatTimeout → task is stale
   - Recovery decision based on attempts:
     - If attempts < maxAttempts: running → queued (no increment)
     - If attempts >= maxAttempts: running → failed (no increment)

## Atomicity and Race Condition Prevention

### Task Claiming
Use atomic SQL operations with conditional WHERE clauses:

```sql
-- Claim a task atomically
UPDATE processed_comments
SET status='running',
    attempts=attempts+1,
    processedAt=datetime('now'),
    heartbeatAt=datetime('now'),
    startedAt=datetime('now'),
    workerPid='<worker-id>',
    leaseExpiresAt=datetime('now', '+<lease-timeout>')
WHERE commentId='<commentId>'
  AND status='queued'
  AND attempts < <maxAttempts>;
```

### Heartbeat Updates
Use atomic UPDATE with workerPid check to ensure only the owning worker can update heartbeat:

```sql
UPDATE processed_comments
SET heartbeatAt=datetime('now'),
    leaseExpiresAt=datetime('now', '+<lease-timeout>')
WHERE commentId='<commentId>'
  AND status='running'
  AND workerPid='<worker-id>'
  AND leaseExpiresAt > datetime('now');
```

## Error Handling and Recovery

### Safe Recovery Operations
All recovery operations use transactions and conditional updates:

```bash
# Safe recovery script pattern
sqlite3 "$DB" "BEGIN TRANSACTION;"
sqlite3 "$DB" "UPDATE processed_comments SET status='<new-status>', ... WHERE commentId='<id>' AND status='<current-status>';"
sqlite3 "$DB" "COMMIT;"
```

### Idempotent Recovery
Recovery operations are idempotent:
- Multiple runs of watchdog have same effect
- Setting status='queued' on already queued task is safe
- Heartbeat updates use lease expiration as guard

## Configuration

```json
{
  "automation": {
    "heartbeatInterval": 60,           // seconds between heartbeats
    "heartbeatTimeout": 900,            // seconds before task is considered stale
    "leaseTimeout": 900,               // total lease duration
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800
  }
}
```

## Integration with Existing Systems

### Poll.sh (Polling Only)
- Removed all recovery logic
- Only handles GitHub polling and task enqueueing
- No modifications to task state beyond 'queued' insertion

### Task Recovery CLI (Manual Recovery)
- Only for manual intervention
- No automatic scheduling
- Provides safe recovery operations for admin use

### Daemon Startup
- Daemon starts with workerPid set in environment
- Worker registers itself when starting
- Ensures single daemon per machine via lock file

## Example Recovery Scenario

### 1. Task Stuck in Running State
```
Time 0: Task queued → worker claims it (status='running', attempts=1, workerPid=W1)
Time 60: Worker crashes (SIGKILL)
Time 65: Watchdog detects stale heartbeat (age=65 > heartbeatTimeout=60)
Time 65: Watchdog runs recovery:
  - attempts=1 < maxAttempts=3
  - running → queued (attempts stays at 1, recovery flag set)
  - Clear workerPid, heartbeatAt, leaseExpiresAt
Time 120: Daemon starts, poll.sh detects status='queued'
  - Task is claimed by orchestrator
  - Worker W2 claims it (status='running', attempts=2, workerPid=W2)
```

### 2. Multiple Worker Failures
```
Time 0: Task queued → worker claims (attempts=1)
Time 60: Worker W1 crashes
Time 65: Watchdog recovers to queued
Time 120: Worker W2 claims (attempts=2)
Time 180: Worker W2 crashes
Time 185: Watchdog recovers to queued
Time 240: Worker W3 claims (attempts=3)
Time 300: Worker W3 crashes
Time 305: Watchdog detects attempts=3 >= maxAttempts=3
  - running → failed (attempts stays at 3, failure flag set)
```

## Monitoring and Debugging

### Task Status Indicators
- `status='running'` with fresh heartbeat: Task active
- `status='running'` with stale heartbeat: Task recovery pending
- `status='queued'` with attempts=1: First attempt (or recovery)
- `status='queued'` with attempts>1: Retry after previous failure

### Log Format
```
[2026-09-02T12:34:56] HEARTBEAT: Task task123 heartbeat updated (worker W2, lease expires 2026-09-02T13:04:56)
[2026-09-02T12:40:01] RECOVERY: Task task123 stale heartbeat (age=360s) → recovery attempts=2/3
[2026-09-02T12:40:01] RECOVERY: Task task123 running → queued (recovery)
[2026-09-02T12:45:01] RECOVERY: Task task123 running → failed (attempts=3 >= max)
```

This updated system provides:
- ✅ Single source of truth (SQLite)
- ✅ Heartbeat/lease for task liveness detection
- ✅ Atomic task claiming with attempt counting
- ✅ Single automatic recovery mechanism (watchdog)
- ✅ Manual recovery tool for admin intervention
- ✅ Proper race condition prevention
- ✅ Idempotent recovery operations
- ✅ Clear state machine semantics
