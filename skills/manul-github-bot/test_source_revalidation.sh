#!/usr/bin/bash
# Focused regression tests for source revalidation (pre-flight check on claim).
# Tests detect_source_kind, revalidate_source, mark_task_stale, requeue_task.
# REST-based tests use a mock gh; GraphQL tests use live gh.
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

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
printf "#!/usr/bin/env bash\nexit 0\n" > "$FAKE_BIN/openclaw"
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

REPO="owner/repo"
GH_API_TIMEOUT=5
PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected='$expected', got='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected rc=$expected, got rc=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

# ── detect_source_kind tests ───────────────────────────────────────────────────
echo "=== detect_source_kind ==="
assert_eq "issue_comment prefix" "issue_comment" "$(detect_source_kind "issue:12345")"
assert_eq "issuebody prefix" "issue_state" "$(detect_source_kind "issuebody:12346")"
assert_eq "ci_fix prefix" "pr_state" "$(detect_source_kind "ci_fix:owner/repo:12347:run1")"
assert_eq "review prefix" "pr_review_comment" "$(detect_source_kind "review:12348")"
assert_eq "unknown defaults to issue_comment" "issue_comment" "$(detect_source_kind "random:123")"

# ── Mock gh for REST-based revalidation tests ──────────────────────────────────
# The mock implements --jq processing so the REST revalidation functions work.
cat >"$FAKE_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# Mock gh — handles --jq and returns appropriate REST responses
cmd_jq=""
url=""
for ((i=1; i<"$#"; i++)); do
  if [[ "${!i}" == --jq ]] && [[ -n "${!((i+1)):-}" ]]; then
    cmd_jq="${!((i+1))}"
  elif [[ "${!i}" != --* ]]; then
    url="${!i}"
  fi
done
# Issue comment REST
if [[ "$url" == */issues/comments/1001 ]]; then
  out='{"id":1001}'; [ -n "$cmd_jq" ] && out="$(printf '%s' "$out" | jq -r "$cmd_jq" 2>/dev/null)"
  printf '%s' "$out"; exit 0
fi
if [[ "$url" == */issues/comments/9999 ]]; then
  out='{"message":"Not Found","status":"404"}'
  printf '%s' "$out"; exit 1
fi
# Issue state REST
if [[ "$url" == */issues/2001 ]]; then
  out='{"state":"open"}'; [ -n "$cmd_jq" ] && out="$(printf '%s' "$out" | jq -r "$cmd_jq" 2>/dev/null)"
  printf '%s' "$out"; exit 0
fi
if [[ "$url" == */issues/2002 ]]; then
  out='{"state":"closed"}'; [ -n "$cmd_jq" ] && out="$(printf '%s' "$out" | jq -r "$cmd_jq" 2>/dev/null)"
  printf '%s' "$out"; exit 0
fi
if [[ "$url" == */issues/9999 ]]; then
  out='{"message":"Not Found","status":"404"}'
  printf '%s' "$out"; exit 1
fi
# PR state REST
if [[ "$url" == */pulls/3001 ]]; then
  out='{"state":"open"}'; [ -n "$cmd_jq" ] && out="$(printf '%s' "$out" | jq -r "$cmd_jq" 2>/dev/null)"
  printf '%s' "$out"; exit 0
fi
if [[ "$url" == */pulls/3002 ]]; then
  out='{"state":"closed"}'; [ -n "$cmd_jq" ] && out="$(printf '%s' "$out" | jq -r "$cmd_jq" 2>/dev/null)"
  printf '%s' "$out"; exit 0
fi
if [[ "$url" == */pulls/3003 ]]; then
  out='{"state":"merged"}'; [ -n "$cmd_jq" ] && out="$(printf '%s' "$out" | jq -r "$cmd_jq" 2>/dev/null)"
  printf '%s' "$out"; exit 0
fi
if [[ "$url" == */pulls/9999 ]]; then
  out='{"message":"Not Found","status":"404"}'
  printf '%s' "$out"; exit 1
fi
exit 1
GHEOF
chmod +x "$FAKE_BIN/gh"

# ── issue_comment revalidation tests ──────────────────────────────────────────
echo "=== issue_comment revalidation ==="
revalidate_issue_comment "issue:1001" "$REPO"
assert_rc "existing issue comment is fresh" 0 $?
revalidate_issue_comment "issue:9999" "$REPO"
assert_rc "deleted issue comment is stale" 1 $?

# ── issue_state revalidation tests ────────────────────────────────────────────
echo "=== issue_state revalidation ==="
revalidate_issue_state "issuebody:2001" "$REPO"
assert_rc "open issue is fresh" 0 $?
revalidate_issue_state "issuebody:2002" "$REPO"
assert_rc "closed issue is stale" 1 $?
revalidate_issue_state "issuebody:9999" "$REPO"
assert_rc "missing issue is stale" 1 $?

# ── pr_state revalidation tests ───────────────────────────────────────────────
echo "=== pr_state revalidation ==="
revalidate_pr_state "ci_fix:owner/repo:3001:run1" "$REPO"
assert_rc "open PR is fresh" 0 $?
revalidate_pr_state "ci_fix:owner/repo:3002:run1" "$REPO"
assert_rc "closed PR is stale" 1 $?
revalidate_pr_state "ci_fix:owner/repo:3003:run1" "$REPO"
assert_rc "merged PR is fresh" 0 $?
revalidate_pr_state "ci_fix:owner/repo:9999:run1" "$REPO"
assert_rc "missing PR is stale" 1 $?

# ── mark_task_stale / requeue_task tests ──────────────────────────────────────
echo "=== mark_task_stale / requeue_task ==="
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('stale-test','$REPO',1,'https://github.com/$REPO/issues/1','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),12345,'token1',NULL,NULL);"
mark_task_stale "stale-test" "stale-test" "token1"
assert_eq "task marked stale" "stale" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='stale-test';")"
assert_eq "claim token cleared on stale" "" "$(sqlite3 "$DB" "SELECT claimToken FROM processed_comments WHERE commentId='stale-test';")"

sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('requeue-test','$REPO',2,'https://github.com/$REPO/issues/2','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),12346,'token2',NULL,NULL);"
requeue_task "requeue-test" "requeue-test" "token2"
assert_eq "task requeued" "queued" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='requeue-test';")"
assert_eq "nextAttemptAt set on requeue" "$(sqlite3 "$DB" "SELECT typeof(nextAttemptAt) FROM processed_comments WHERE commentId='requeue-test';")" "text"

# ── GraphQL-based review comment tests (live gh, no mock) ─────────────────────
echo "=== pr_review_comment revalidation (live) ==="
# Remove mock gh from PATH for live GraphQL tests
PATH="${PATH#"$FAKE_BIN":}"
GH_API_TIMEOUT=10
# Use real GitHub data for PR 21340 which has known review threads
revalidate_pr_review_comment "review:4056613546" "eslint/eslint"
assert_rc "unresolved review thread is fresh" 0 $?
revalidate_pr_review_comment "review:4058170054" "eslint/eslint"
assert_rc "resolved review thread is stale" 1 $?
revalidate_pr_review_comment "review:999999999" "eslint/eslint"
assert_rc "nonexistent review thread is stale" 1 $?
revalidate_pr_review_comment "review:12345" "eslint/nonexistent-pr-99999"
assert_rc "nonexistent PR is stale" 1 $?

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
