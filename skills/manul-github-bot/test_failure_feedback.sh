#!/usr/bin/env bash
# Regression tests for terminal failure delivery: stage metadata, redaction,
# overlapping-handler deduplication, and preservation of DB failure state.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export DB="$MANUL_DIR/state/manul.db"
export MANUL_MODE=bot
export GH_COMMENTS_JSONL="$TEST_DIR/github-comments.jsonl"
export GH_CALL_LOG="$TEST_DIR/github-calls.log"
mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/logs" "$TEST_DIR/bin"
: > "$GH_COMMENTS_JSONL"
: > "$GH_CALL_LOG"

cat > "$MANUL_DIR/config.json" <<'JSON'
{
  "mode": "bot",
  "automation": {
    "maxAttemptsBeforeFail": 1,
    "maxTaskRunningTime": 1,
    "heartbeatTimeout": 1,
    "leaseTimeout": 1
  },
  "retryConfig": { "delaySeconds": 1 }
}
JSON

sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT,
  issueNumber INTEGER,
  commentUrl TEXT,
  action TEXT,
  status TEXT,
  attempts INTEGER,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  claimToken TEXT,
  nextAttemptAt TEXT,
  conversationId TEXT
);
SQL

cat > "$TEST_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'CALL:%s\n' "$*" >> "$GH_CALL_LOG"

if [[ "${1:-}" == "api" ]]; then
  if [ -s "$GH_COMMENTS_JSONL" ]; then
    jq -s '.' "$GH_COMMENTS_JSONL"
  else
    printf '[]\n'
  fi
  exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
  if [ "${GH_FAIL_POST:-0}" = "1" ]; then
    echo "simulated GitHub comment failure" >&2
    exit 1
  fi
  body=""
  while (($#)); do
    if [[ "$1" == "--body" ]]; then
      body="$2"
      shift 2
    else
      shift
    fi
  done
  jq -nc --arg body "$body" '{body:$body}' >> "$GH_COMMENTS_JSONL"
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 2
GH
chmod +x "$TEST_DIR/bin/gh"
export PATH="$TEST_DIR/bin:$PATH"

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $message (expected=$expected actual=$actual)" >&2
    exit 1
  fi
  echo "PASS: $message"
}

count_for_task() {
  jq -s --arg task "$1" '[.[] | select(((.body // "") | contains("\"type\":\"TASK_FAILED\"")) and ((.body // "") | contains("\"taskId\":\"" + $task + "\"")))] | length' "$GH_COMMENTS_JSONL"
}

insert_task() {
  local id="$1" issue="$2" status="$3" attempts="$4" processed="${5:-NULL}"
  local safe_id
  safe_id="$(printf '%s' "$id" | sed "s/'/''/g")"
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,attempts,processedAt,heartbeatAt,leaseExpiresAt,workerPid,claimToken,conversationId) VALUES ('$safe_id','test/repo',$issue,'https://github.com/test/repo/issues/$issue','$status',$attempts,$processed,datetime('now'),datetime('now','+10 seconds'),$$,'claim-$safe_id','');"
}

# A diagnostic early failure must publish task id, stage and useful context while
# redacting credential-like strings and well-known provider-token formats.
insert_task "early-failure" 71 failed 3
sensitive_error='workspace lookup failed: password=hunter2 access_token=verysecretvalue Authorization: Bearer BearerSecretValue12345 ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
MANUL_DIR="$MANUL_DIR" DB="$DB" bash "$SCRIPT_DIR/manul-result-feedback.sh" post-failed \
  --repo test/repo --issue 71 --comment-id early-failure --task-id early-failure \
  --stage workspace_path_validation --error "$sensitive_error" >/dev/null
assert_eq 1 "$(count_for_task early-failure)" "early workspace failure comment published once"
body="$(jq -s -r '[.[] | select((.body // "") | contains("\"taskId\":\"early-failure\""))][0].body' "$GH_COMMENTS_JSONL")"
grep -q '\*\*Task:\*\* early-failure' <<< "$body" || { echo "FAIL: comment missing task id" >&2; exit 1; }
grep -q '\*\*Stage:\*\* workspace_path_validation' <<< "$body" || { echo "FAIL: comment missing failure stage" >&2; exit 1; }
grep -q '\[REDACTED\]' <<< "$body" || { echo "FAIL: comment does not show redaction" >&2; exit 1; }
if grep -Eq 'hunter2|verysecretvalue|BearerSecretValue12345|ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456' <<< "$body"; then
  echo "FAIL: a credential-like value leaked into the GitHub comment" >&2
  exit 1
fi
echo "PASS: failure comment redacts credential-like details"

# Two overlapping publishers for the same terminal task/attempt must serialize
# and produce one GitHub comment.
insert_task "overlap-failure" 72 failed 2
publish_overlap() {
  MANUL_DIR="$MANUL_DIR" DB="$DB" bash "$SCRIPT_DIR/manul-result-feedback.sh" post-failed \
    --repo test/repo --issue 72 --comment-id overlap-failure --task-id overlap-failure \
    --stage stale_task_recovery --error 'stale lease recovery exhausted retries' >/dev/null
}
publish_overlap & p1=$!
publish_overlap & p2=$!
wait "$p1"
wait "$p2"
assert_eq 1 "$(count_for_task overlap-failure)" "overlapping failure publishers are deduplicated"

# Exercise the real task-health-check entry point and verify a terminal task
# stays failed even when GitHub rejects the comment publication.
insert_task "health-stuck" 73 running 1 "datetime('now','-30 seconds')"
MANUL_DIR="$MANUL_DIR" DB="$DB" bash "$SCRIPT_DIR/task-health-check.sh" >"$TEST_DIR/health-ok.log" 2>&1
assert_eq failed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='health-stuck';")" "health check persists terminal failure"
health_comment_count="$(count_for_task health-stuck)"
if [ "$health_comment_count" != "1" ]; then
  echo "FAIL: health-check terminal failure comment published (expected=1 actual=$health_comment_count)" >&2
  echo "--- health-check log ---" >&2
  cat "$TEST_DIR/health-ok.log" >&2
  echo "--- GitHub mock calls ---" >&2
  cat "$GH_CALL_LOG" >&2
  echo "--- recorded GitHub comments ---" >&2
  cat "$GH_COMMENTS_JSONL" >&2
  exit 1
fi
echo "PASS: health-check terminal failure comment published"
health_body="$(jq -s -r '[.[] | select((.body // "") | contains("\"taskId\":\"health-stuck\""))][0].body' "$GH_COMMENTS_JSONL")"
grep -q '\*\*Stage:\*\* task_health_check' <<< "$health_body" || { echo "FAIL: health-check comment missing stage" >&2; exit 1; }

insert_task "health-api-failure" 74 running 1 "datetime('now','-30 seconds')"
export GH_FAIL_POST=1
MANUL_DIR="$MANUL_DIR" DB="$DB" bash "$SCRIPT_DIR/task-health-check.sh" >"$TEST_DIR/health-api-failure.log" 2>&1
assert_eq failed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='health-api-failure';")" "GitHub publication error does not roll back task failure"
assert_eq 0 "$(count_for_task health-api-failure)" "failed GitHub publication is not recorded as posted"
grep -q 'terminal failure comment could not be posted for health-api-failure' "$TEST_DIR/health-api-failure.log" || {
  echo "FAIL: publication failure was not logged separately" >&2
  cat "$TEST_DIR/health-api-failure.log" >&2
  exit 1
}
echo "PASS: GitHub publication failure is logged without hiding task failure"

echo "All terminal failure feedback tests passed."
