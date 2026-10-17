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
  workerPid INTEGER
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
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,baseId)
VALUES ('1001','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1001','queued','1001');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,baseId)
VALUES ('review:2002','owner/repo',12,'https://github.com/owner/repo/pull/12#discussion_r2002','failed','2002');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,taskSourceType,taskSourceId)
VALUES ('source:github_issues:owner/repo#9','owner/repo',9,'https://github.com/owner/repo/issues/9','queued','github_issues','owner/repo#9');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status)
VALUES ('1003','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1003','running');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status)
VALUES ('1004','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1004','completed');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status)
VALUES ('1005','owner/repo',9,'https://github.com/owner/repo/issues/9#issuecomment-1005','blocked_user');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status)
VALUES ('cli-task','owner/repo',9,'https://github.com/owner/repo/issues/9','queued');
INSERT INTO conversation_messages(messageId,conversationId,commentId,repo,issueNumber,author,body,commentUrl,createdAt,messageType)
VALUES ('m1','conv-9','1001','owner/repo',9,'user','/manul work','https://github.com/owner/repo/issues/9#issuecomment-1001','2026-10-17T10:00:00Z','comment');
INSERT INTO conversation_messages(messageId,conversationId,commentId,repo,issueNumber,author,body,commentUrl,createdAt,messageType)
VALUES ('m2','conv-12','2002','owner/repo',12,'user','/manul review-fix','https://github.com/owner/repo/pull/12#discussion_r2002','2026-10-17T10:01:00Z','review');
INSERT INTO conversation_messages(messageId,conversationId,commentId,repo,issueNumber,author,body,commentUrl,createdAt,messageType)
VALUES ('m3','conv-9','follow-up','owner/repo',9,'user','follow-up context','https://github.com/owner/repo/issues/9#issuecomment-1100','2026-10-17T10:02:00Z','comment');
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
assert_contains "dry-run reports replayable tasks" "$DRY_OUTPUT" "replayable_total=3"
assert_eq "dry-run leaves candidate rows in place" "3" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId IN ('1001','review:2002','source:github_issues:owner/repo#9');")"
assert_eq "dry-run does not invoke poll" "0" "$([ -f "$POLL_CALL_FILE" ] && wc -l < "$POLL_CALL_FILE" || echo 0)"

EXEC_OUTPUT="$(printf 'RESET QUEUE\n' | MANUL_DIR="$MANUL_DIR" DB="$DB" MANUL_POLL_SCRIPT="$POLL_SCRIPT" POLL_CALL_FILE="$POLL_CALL_FILE" bash "$SCRIPT_DIR/manul-queue-reset.sh" --execute)"
assert_contains "execute invokes poll and reports result" "$EXEC_OUTPUT" 'MANUL_RESULT {"fire":true,"new":1,"pending":1}'
assert_eq "poll invoked exactly once" "1" "$(wc -l < "$POLL_CALL_FILE" | tr -d ' ')"
assert_eq "GitHub trigger was rediscovered by poll" "queued" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='1001';")"
assert_eq "failed review trigger dedupe is cleared" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages WHERE commentId='2002';")"
assert_eq "unrelated conversation context survives" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages WHERE commentId='follow-up';")"
assert_eq "running task is preserved" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='1003' AND status='running';")"
assert_eq "completed task is preserved" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='1004' AND status='completed';")"
assert_eq "blocked-user task is preserved" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='1005' AND status='blocked_user';")"
assert_eq "manually submitted queued task is preserved" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='cli-task' AND status='queued';")"
assert_eq "source-backed task is removed for provider re-poll" "0" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='source:github_issues:owner/repo#9';")"

BACKUP_PATH="$(printf '%s\n' "$EXEC_OUTPUT" | sed -n 's/^Backup: //p' | head -n1)"
[ -n "$BACKUP_PATH" ] && [ -f "$BACKUP_PATH" ] || fail "database backup exists"
assert_eq "database backup passes integrity check" "ok" "$(sqlite3 "$BACKUP_PATH" "PRAGMA integrity_check;")"

echo "All queue-reset tests passed."
