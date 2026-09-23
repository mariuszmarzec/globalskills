#!/bin/bash
# test_poll_result_parsing.sh — regression tests for daemon poll-result handling.
#
# Guards against the production regression where a literal "\n" was passed to
# printf, causing malformed JSON, multi-value jq output, and a false dispatch gate.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/manul.db"
CONFIG="$MANUL_DIR/config.json"
LOG="$MANUL_DIR/daemon.log"
LIFECYCLE_LOG="$MANUL_DIR/lifecycle.log"
LAST_POLL_FILE="$MANUL_DIR/last-poll"
export MANUL_DIR DB CONFIG LOG LIFECYCLE_LOG LAST_POLL_FILE MANUL_TESTING=true

mkdir -p "$MANUL_DIR/workspaces"
cat >"$CONFIG" <<'EOF'
{
  "pollInterval": 60,
  "repositories": [],
  "automation": {
    "maxConcurrentTasks": 1,
    "maxAttemptsBeforeFail": 3,
    "heartbeatInterval": 60,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900
  },
  "retryConfig": {
    "delaySeconds": 60
  }
}
EOF

# Load only the exact production function bodies under test; do not execute daemon CLI/bootstrap code.
log() { :; }
eval "$(sed -n '/^parse_poll_result() {/,/^}/p' "$SCRIPT_DIR/manul-daemon.sh")"
eval "$(sed -n '/^eligible_queued_count() {/,/^}/p' "$SCRIPT_DIR/manul-daemon.sh")"

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name: expected [$expected], got [$actual]" >&2
    exit 1
  fi
}

echo "=== Parser: clean queued result ==="
result="$(parse_poll_result 'diagnostic
MANUL_RESULT {"fire":true,"new":0,"pending":1}')"
assert_eq "clean-fire" "true|0|1" "$result"

echo "=== Parser: two MANUL_RESULT lines, last one wins ==="
result="$(parse_poll_result $'MANUL_RESULT {"fire":true,"new":1,"pending":1}\nMANUL_RESULT {"fire":false,"new":0,"pending":1}')"
assert_eq "multi-line" "false|0|1" "$result"

echo "=== Parser: malformed literal backslash-n suffix is rejected ==="
result="$(parse_poll_result 'MANUL_RESULT {"fire":true,"new":0,"pending":1}\n')"
assert_eq "literal-backslash-n" "false|0|0" "$result"

echo "=== Parser: non-object JSON is rejected ==="
result="$(parse_poll_result 'MANUL_RESULT []')"
assert_eq "non-object" "false|0|0" "$result"

echo "=== Parser: no result defaults safely ==="
result="$(parse_poll_result 'poll diagnostic only')"
assert_eq "empty" "false|0|0" "$result"

echo "=== Queue eligibility: attempts=0 is runnable ==="
sqlite3 "$DB" "CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  nextAttemptAt TEXT
);"
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('a','queued',0,NULL);"
assert_eq "eligible-attempt-zero" "1" "$(eligible_queued_count)"

echo "=== Queue eligibility: due retry is runnable ==="
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('b','queued',1,datetime('now','-1 minute'));"
assert_eq "eligible-due-retry" "2" "$(eligible_queued_count)"

echo "=== Queue eligibility: future retry is not runnable ==="
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('c','queued',1,'2099-01-01 00:00:00');"
assert_eq "future-retry-filtered" "2" "$(eligible_queued_count)"

echo "All poll-result parsing tests passed."
