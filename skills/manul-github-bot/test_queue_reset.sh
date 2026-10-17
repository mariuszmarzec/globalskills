#!/usr/bin/env bash
# Behavioral regression tests for manul-queue-reset.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEST_ROOT="$(mktemp -d /tmp/manul-queue-reset-XXXXXX)"
MANUL_DIR="$TEST_ROOT/runtime"
DB="$MANUL_DIR/state/manul.db"
POLL_SCRIPT="$MANUL_DIR/poll.sh"
POLL_CALL_FILE="$TEST_ROOT/poll-called"
mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/state"

cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  local description="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$description (expected=$expected actual=$actual)"
  pass "$description"
}
assert_contains() {
  local description="$1" text="$2" expected="$3"
  printf '%s' "$text" | grep -Fq -- "$expected" || fail "$description (missing: $expected)"
  pass "$description"
}

sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  baseId TEXT,
  taskSourceType TEXT,
  taskSourceId TEXT,
  workerPid INTEGER,
  claimToken TEXT
);
CREATE TABLE conversation_messages (
  messageId TEXT PRIMARY KEY,
  conversationId TEXT NOT NULL,
  commentId TEXT,
  repo TEXT,
  issueNumber INTEGER,
  author TEXT,
  body TEXT,
  commentUrl TEXT,
  createdAt TEXT,
  messageType TEXT
);
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  activeTaskId TEXT
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO conversations(conversationId,status,activeTaskId) VALUES ('conv-9','OPEN','1001');
INSERT INTO conversations(conversationId,status,activeTaskId) VALUES ('conv-12','OPEN','review:2002');
INSERT INTO meta(key,value) VALUES ('baseline','2026-10-01T00:00:00Z');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,baseId)
VALUES ('1001','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1001','queued','1001');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,baseId)
VALUES ('review:2002','owner/repo',12,'https://github.com/owner/repo/pull/12#discussion_r2002','failed','2002');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,baseId)
VALUES ('issue:3003','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-3003','queued','issue:3003');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,baseId)
VALUES ('issuebody:4004','owner/repo',9,'https://github.com/owner/repo/issues/9','queued','issuebody:4004');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,taskSourceType,taskSourceId)
VALUES ('source:github_issues:owner/repo#9','owner/repo',9,'https://github.com/owner/repo/issues/9','queued','github_issues','owner/repo#9');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status)
VALUES ('1003','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1003','running');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status)
VALUES ('1004','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1004','completed');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status)
VALUES ('1005','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1005','blocked_user');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,workerPid)
VALUES ('1006','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1006','stale',99999999);
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status)
VALUES ('cli-task','owner/repo',9,'https://github.com/owner/repo/issues/9','queued');
INSERT INTO conversation_messages(messageId,conversationId,commentId,repo,issueNumber,author,body,commentUrl,createdAt,messageType)
VALUES ('m1','conv-9','1001','owner/repo',9,'user','/manul work','https://github.com/owner/repo/issues/9#issuecomment-1001','2026-10-17T10:00:00Z','comment');
INSERT INTO conversation_messages(messageId,conversationId,commentId,repo,issueNumber,author,body,commentUrl,createdAt,messageType)
VALUES ('m2','conv-12','2002','owner/repo',12,'user','/manul review-fix','https://github.com/owner/repo/pull/12#discussion_r2002','2026-10-17T10:01:00Z','review');
INSERT INTO conversation_messages(messageId,conversationId,commentId,repo,issueNumber,author,body,commentUrl,createdAt,messageType)
VALUES ('m3','conv-9','follow-up','owner/repo',9,'user','follow-up context','https://github.com/owner/repo/issues/9#issuecomment-1100','2026-10-17T10:02:00Z','comment');
INSERT INTO conversation_messages(messageId,conversationId,commentId,repo,issueNumber,author,body,commentUrl,createdAt,messageType)
VALUES ('m4','conv-9','3003','owner/repo',9,'user','/manul retry issue comment','https://github.com/owner/repo/issues/9#issuecomment-3003','2026-10-17T10:03:00Z','comment');
INSERT INTO conversation_messages(messageId,conversationId,commentId,repo,issueNumber,author,body,commentUrl,createdAt,messageType)
VALUES ('m5','conv-9','4004','owner/repo',9,'user','/manul issue body','https://github.com/owner/repo/issues/9','2026-10-17T10:04:00Z','issue');
SQL

cat > "$POLL_SCRIPT" <<'POLL'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >> "$POLL_CALL_FILE"
sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,baseId) VALUES ('1001','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1001','queued','1001');"
echo 'MANUL_RESULT {"fire":true,"new":1,"pending":1}'
POLL
chmod +x "$POLL_SCRIPT"

DRY_OUTPUT="$(MANUL_DIR="$MANUL_DIR" DB="$DB" MANUL_POLL_SCRIPT="$POLL_SCRIPT" bash "$SCRIPT_DIR/manul-queue-reset.sh" --dry-run)"
assert_contains "dry-run reports replayable tasks" "$DRY_OUTPUT" "replayable_total=5"
assert_eq "dry-run leaves all replayable candidate rows in place" "5" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId IN ('1001','review:2002','source:github_issues:owner/repo#9','issue:3003','issuebody:4004');")"
assert_eq "dry-run does not invoke poll" "0" "$([ -f "$POLL_CALL_FILE" ] && wc -l < "$POLL_CALL_FILE" || echo 0)"

EXEC_OUTPUT="$(printf 'RESET QUEUE\n' | MANUL_DIR="$MANUL_DIR" DB="$DB" MANUL_POLL_SCRIPT="$POLL_SCRIPT" POLL_CALL_FILE="$POLL_CALL_FILE" bash "$SCRIPT_DIR/manul-queue-reset.sh" --execute)"
assert_contains "execute invokes poll and reports result" "$EXEC_OUTPUT" 'MANUL_RESULT {"fire":true,"new":1,"pending":1}'
assert_eq "poll invoked exactly once" "1" "$(wc -l < "$POLL_CALL_FILE" | tr -d ' ')"
assert_eq "GitHub trigger was rediscovered by poll" "queued" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='1001';")"
assert_eq "failed review trigger dedupe is cleared" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages WHERE commentId='2002';")"
assert_eq "unrelated conversation context survives" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages WHERE commentId='follow-up';")"
assert_eq "canonical issue comment task is removed for re-poll" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:3003';")"
assert_eq "canonical issue-body task is removed for re-poll" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issuebody:4004';")"
assert_eq "raw issue comment dedupe message is cleared" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages WHERE commentId='3003';")"
assert_eq "raw issue-body dedupe message is cleared" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages WHERE commentId='4004';")"
assert_eq "running task is preserved" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='1003' AND status='running';")"
assert_eq "completed task is preserved" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='1004' AND status='completed';")"
assert_eq "blocked-user task is preserved" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='1005' AND status='blocked_user';")"
assert_eq "stale task carrying worker ownership is preserved" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='1006' AND status='stale' AND workerPid=99999999;")"
assert_eq "manually submitted queued task is preserved" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='cli-task' AND status='queued';")"
assert_eq "source-backed task is removed for provider re-poll" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='source:github_issues:owner/repo#9';")"

BACKUP_PATH="$(printf '%s\n' "$EXEC_OUTPUT" | sed -n 's/^Backup: //p' | head -n1)"
[ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ] || fail "database backup exists"
assert_eq "database backup passes integrity check" "ok" "$(sqlite3 "$BACKUP_PATH" "PRAGMA integrity_check;")"

# A live poll lock should be waited out, not treated as a stale file to delete.
sqlite3 "$DB" <<'SQL'
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,baseId)
VALUES ('1007','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1007','failed','1007');
INSERT INTO conversation_messages(messageId,conversationId,commentId,repo,issueNumber,author,body,commentUrl,createdAt,messageType)
VALUES ('m7','conv-9','1007','owner/repo',9,'user','/manul retry','https://github.com/owner/repo/issues/9#issuecomment-1007','2026-10-17T10:07:00Z','comment');
SQL

LOCK_READY="$TEST_ROOT/poll-lock-ready"
(
  exec 200>"$MANUL_DIR/state/locks/poll.flock"
  flock -n 200
  touch "$LOCK_READY"
  sleep 2
) &
LOCK_PID=$!
for _ in {1..50}; do
  [ -f "$LOCK_READY" ] && break
  sleep 0.1
done
[ -f "$LOCK_READY" ] || fail "test poll-lock holder acquired the flock"
WAIT_OUTPUT="$(printf 'RESET QUEUE\n' | MANUL_DIR="$MANUL_DIR" DB="$DB" MANUL_POLL_SCRIPT="$POLL_SCRIPT" POLL_CALL_FILE="$POLL_CALL_FILE" MANUL_QUEUE_RESET_LOCK_WAIT_SECONDS=5 bash "$SCRIPT_DIR/manul-queue-reset.sh" --execute)"
wait "$LOCK_PID"
assert_contains "execute waits for a busy poll lock" "$WAIT_OUTPUT" "Waiting up to 5s for the current poll to finish"
assert_contains "execute proceeds after poll lock is released" "$WAIT_OUTPUT" "Reset/re-poll complete"
assert_eq "poll invoked again after lock release" "2" "$(wc -l < "$POLL_CALL_FILE" | tr -d ' ')"
assert_eq "reset removes the replayable task after waiting for the poll" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='1007';")"

# Full reset is intentionally blocked while running/worker-owned rows exist.
FULL_BLOCKED_LOG="$TEST_ROOT/full-reset-blocked.log"
if printf 'DELETE ALL TASKS\n' | MANUL_DIR="$MANUL_DIR" DB="$DB" MANUL_POLL_SCRIPT="$POLL_SCRIPT" POLL_CALL_FILE="$POLL_CALL_FILE" bash "$SCRIPT_DIR/manul-queue-reset.sh" --all-tasks --execute >"$FULL_BLOCKED_LOG" 2>&1; then
  fail "full reset must refuse active or worker-owned tasks"
fi
FULL_BLOCKED_OUTPUT="$(cat "$FULL_BLOCKED_LOG")"
assert_contains "full reset refuses active tasks" "$FULL_BLOCKED_OUTPUT" "No task data was changed"
assert_eq "blocked full reset preserves task rows" "6" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;")"
assert_eq "blocked full reset preserves message dedupe/context" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages;")"
assert_eq "blocked full reset preserves conversations" "2" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversations;")"

# Simulate an operator verifying that the old running/assigned rows no longer
# have a live worker, then preview the destructive mode before execution.
sqlite3 "$DB" "UPDATE processed_comments SET status='completed', workerPid=NULL, claimToken=NULL WHERE commentId='1003'; UPDATE processed_comments SET workerPid=NULL, claimToken=NULL WHERE commentId='1006';"
FULL_DRY_OUTPUT="$(MANUL_DIR="$MANUL_DIR" DB="$DB" MANUL_POLL_SCRIPT="$POLL_SCRIPT" bash "$SCRIPT_DIR/manul-queue-reset.sh" --all-tasks --dry-run)"
assert_contains "full reset preview lists every task row" "$FULL_DRY_OUTPUT" "all_task_rows=6"
assert_contains "full reset preview lists conversation messages" "$FULL_DRY_OUTPUT" "conversation_messages=1"
assert_contains "full reset preview lists conversations" "$FULL_DRY_OUTPUT" "conversations=2"
assert_eq "full reset preview does not change task rows" "6" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;")"

FULL_OUTPUT="$(printf 'DELETE ALL TASKS\n' | MANUL_DIR="$MANUL_DIR" DB="$DB" MANUL_POLL_SCRIPT="$POLL_SCRIPT" POLL_CALL_FILE="$POLL_CALL_FILE" bash "$SCRIPT_DIR/manul-queue-reset.sh" --all-tasks --execute)"
assert_contains "full reset re-polls configured sources" "$FULL_OUTPUT" "Reset/re-poll complete"
assert_contains "full reset reports removed task rows" "$FULL_OUTPUT" "Removed task rows: 6"
assert_eq "poll invoked once by full reset" "3" "$(wc -l < "$POLL_CALL_FILE" | tr -d ' ')"
assert_eq "full reset deletes prior task history before re-poll" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;")"
assert_eq "mock poller recreated only its discovered task" "queued" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='1001';")"
assert_eq "full reset clears conversation message dedupe/context" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages;")"
assert_eq "full reset clears stale conversation routing" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversations;")"
assert_eq "full reset preserves install baseline" "2026-10-01T00:00:00Z" "$(sqlite3 "$DB" "SELECT value FROM meta WHERE key='baseline';")"
FULL_BACKUP_PATH="$(printf '%s\n' "$FULL_OUTPUT" | sed -n 's/^Backup: //p' | head -n1)"
[ -n "$FULL_BACKUP_PATH" ] && [ -f "$FULL_BACKUP_PATH" ] || fail "full-reset database backup exists"
assert_eq "full-reset backup passes integrity check" "ok" "$(sqlite3 "$FULL_BACKUP_PATH" "PRAGMA integrity_check;")"

echo "All queue-reset tests passed."
