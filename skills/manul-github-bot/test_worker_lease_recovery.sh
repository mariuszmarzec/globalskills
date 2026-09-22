#!/usr/bin/bash
# Focused regression tests for worker ownership, heartbeat/lease and recovery.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/manul.db"
CONFIG="$MANUL_DIR/config.json"
LOG="$MANUL_DIR/daemon.log"
LIFECYCLE_LOG="$MANUL_DIR/lifecycle.log"
PID_FILE="$MANUL_DIR/daemon.pid"
mkdir -p "$MANUL_DIR"

cat >"$CONFIG" <<'JSON'
{
  "autoCreatePr": false,
  "automation": {
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900
  },
  "retryConfig": {
    "delaySeconds": 1
  }
}
JSON

export MANUL_DIR DB CONFIG LOG LIFECYCLE_LOG PID_FILE MANUL_TESTING=true
# The daemon resolves OPENCLAW_BIN from PATH while sourcing. This focused unit
# test never invokes OpenClaw, so provide a hermetic stub for that lookup.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
printf "#!/usr/bin/env bash\\nexit 0\\n" > "$FAKE_BIN/openclaw"
chmod +x "$FAKE_BIN/openclaw"
export PATH="$FAKE_BIN:$PATH"
# Source under a controlled errexit boundary so a future daemon initialization
# regression is reported in this test instead of terminating the shell silently.
set +e
source "$SCRIPT_DIR/manul-daemon.sh"
SOURCE_RC=$?
set -e
if [ "$SOURCE_RC" -ne 0 ]; then
  echo "FAIL: sourcing manul-daemon.sh returned rc=$SOURCE_RC" >&2
  cat "$LIFECYCLE_LOG" 2>/dev/null || true
  exit 1
fi
# manul-daemon.sh prepends its runtime PATH while sourcing, so restore the
# fake-bin precedence for the gh calls used by this hermetic test.
export PATH="$FAKE_BIN:$PATH"

sqlite3 "$DB" "
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  action TEXT,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  claimToken TEXT,
  nextAttemptAt TEXT,
  resultSummary TEXT
);
"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $label (expected=$expected actual=$actual)" >&2
    exit 1
  fi
  echo "PASS: $label"
}

REPO="owner/repo"

# 1) Completion succeeds only for the worker owning the lease.
sqlite3 "$DB" "
INSERT INTO processed_comments VALUES
('owner','$REPO',1,'https://github.com/$REPO/issues/1','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),12345,'owner-token',NULL,NULL);
INSERT INTO processed_comments VALUES
('other','$REPO',2,'https://github.com/$REPO/issues/2','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),999999,'other-token',NULL,NULL);
"
update_task_completion owner completed "" owner-token
assert_eq completed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='owner';")" "owner can complete"
if update_task_completion other completed "" wrong-token; then
  echo "FAIL: non-owner completion unexpectedly succeeded" >&2
  exit 1
fi
echo "PASS: non-owner completion rejected"

# 2) Heartbeat refresh updates both heartbeatAt and leaseExpiresAt.
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('123','$REPO',3,'https://github.com/$REPO/issues/3','IMPLEMENT','running',1,datetime('now','-1 hour'),datetime('now','-1 hour'),datetime('now','-1 second'),123,'123-token',NULL,NULL);"
HEARTBEAT_PIDS[123]=1
CURRENT_WORKER_PID=123
LEASE_TIMEOUT=900
refresh_heartbeat 123
assert_eq 1 "$(sqlite3 "$DB" "SELECT CASE WHEN heartbeatAt > datetime('now','-5 seconds') THEN 1 ELSE 0 END FROM processed_comments WHERE commentId='123';")" "heartbeat timestamp refreshed"
assert_eq 1 "$(sqlite3 "$DB" "SELECT CASE WHEN leaseExpiresAt > datetime('now') THEN 1 ELSE 0 END FROM processed_comments WHERE commentId='123';")" "lease expiry extended"

# 3) Dead worker + expired lease is requeued.
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('dead','$REPO',4,'https://github.com/$REPO/issues/4','IMPLEMENT','running',1,datetime('now','-1 hour'),datetime('now','-1 hour'),datetime('now','-1 second'),999999,'dead-token',NULL,NULL);"
recover_stale_tasks
assert_eq queued "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='dead';")" "dead worker task requeued"

# 4) Live worker + expired lease is recovered; worker PID alone is not task ownership.
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('live','$REPO',5,'https://github.com/$REPO/issues/5','IMPLEMENT','running',1,datetime('now','-1 hour'),datetime('now','-1 hour'),datetime('now','-1 second'),1,'live-token',NULL,NULL);"
recover_stale_tasks
assert_eq queued "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='live';")" "live worker task recovered by expired lease"
# Simulate the same long-lived worker claiming the retry with a new token. The old execution must not finalize it.
sqlite3 "$DB" "UPDATE processed_comments SET status='running', heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now','+900 seconds'), workerPid=1, claimToken='new-token' WHERE commentId='live';"
if update_task_completion live completed "" live-token; then
  echo "FAIL: stale claim unexpectedly finalized a newer execution" >&2
  exit 1
fi
assert_eq running "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='live';")" "stale claim cannot finalize newer execution"
update_task_completion live completed "" new-token
assert_eq completed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='live';")" "current claim can finalize"

# 5) Max attempts on dead worker becomes failed.
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('maxed','$REPO',6,'https://github.com/$REPO/issues/6','IMPLEMENT','running',3,datetime('now','-1 hour'),datetime('now','-1 hour'),datetime('now','-1 second'),999998,'maxed-token',NULL,NULL);"
recover_stale_tasks
assert_eq failed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='maxed';")" "max-attempt task failed"

# 6) PR verification rejects a missing PR and accepts a real PR.
WORKTREE="$TEST_DIR/repo"
mkdir -p "$WORKTREE"
git -C "$WORKTREE" init -q
git -C "$WORKTREE" config user.email test@example.com
git -C "$WORKTREE" config user.name test
printf 'test\n' >"$WORKTREE/README.md"
git -C "$WORKTREE" add README.md
git -C "$WORKTREE" commit -qm initial
git -C "$WORKTREE" checkout -qb manul-task-test

sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('pr','$REPO',7,'https://github.com/$REPO/issues/7','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),12345,'pr-token',NULL,NULL);"

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"pr list"* ]]; then
  if [ "${FAKE_PR_EXISTS:-0}" = "1" ]; then
    printf '[{"number":123,"url":"https://github.com/example/repo/pull/123","state":"OPEN"}]\n'
  else
    printf '[]\n'
  fi
  exit 0
fi
exit 1
GH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"
GH_API_TIMEOUT=2

if verify_required_pr "$REPO" pr "$WORKTREE" master; then
  echo "FAIL: missing PR was accepted" >&2
  exit 1
fi
echo "PASS: missing PR rejected"

export FAKE_PR_EXISTS=1
verify_required_pr "$REPO" pr "$WORKTREE" master
echo "PASS: real PR accepted"

echo "All focused worker lifecycle tests passed."
exit 0
