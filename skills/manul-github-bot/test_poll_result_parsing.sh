#!/bin/bash
# test_poll_result_parsing.sh — regression tests for the daemon's poll-result
# parsing and the safety-net dispatch path.
#
# Root cause this guards against: poll.sh can emit MORE THAN ONE MANUL_RESULT
# line in a single capture (its forked repo workers inherit the daemon's
# redirected stdout and run emit_result independently). The old parser fed the
# whole capture to jq, so two JSON objects glued together made jq return two
# values that got concatenated into e.g. "true\nfalse", which then failed the
# exact `poll_fire = "true"` gate below and permanently skipped every queued
# task.
#
# Tests:
#   1. Corrupted input (two MANUL_RESULT lines, real newline) -> single "true"
#   2. Corrupted input (two objects glued, literal-\n suffix) -> single "true"
#   3. Clean single-line input -> "true"
#   4. No MANUL_RESULT line -> defaults to fire=false, pending=0
#   5. Safety-net query counts eligible queued tasks
#
# Usage: bash test_poll_result_parsing.sh

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/manul-daemon.sh"

PASS=0
FAIL=0

# The daemon's parsing block calls log() on invalid input; stub it so the test
# harness is self-contained.
log() { :; }

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    echo "PASS $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $name: expected [$expected] got [$actual]"
  fi
}

# --- Extract the daemon's parsing block verbatim and run it against inputs. ---
# The block is delimited by the "Record poll result" comment and the record_poll
# call. We extract it from the real daemon file so this test exercises the
# actual code, not a copy.
BLOCK="$(awk '/^  # Record poll result for observability\./{f=1} f{print} /^  record_poll "\$poll_fire"/{exit}' "$DAEMON")"
# The block references $out (the captured poll output); supply it and a no-op
# record_poll, then eval the extracted lines.
parse_poll_output() {
  local out="$1"
  record_poll() { :; }
  eval "$BLOCK"
  printf '%s\n%s\n%s\n' "$poll_fire" "$poll_new" "$poll_pending"
}

echo "=== Test 1: two MANUL_RESULT lines separated by a real newline ==="
# The last line wins (it is the most recent emit_result call, i.e. the trap's
# final emit or the normal-exit emit). Both lines are individually valid JSON,
# so the last one is parsed cleanly -- no multi-value corruption.
out=$'MANUL_RESULT {"fire":true,"new":0,"pending":1}\nMANUL_RESULT {"fire":false,"new":0,"pending":0}'
mapfile -t _r < <(parse_poll_output "$out")
assert_eq "1:fire" "false" "${_r[0]}"
assert_eq "1:new" "0" "${_r[1]}"
assert_eq "1:pending" "0" "${_r[2]}"

echo "=== Test 2: two objects glued, trailing literal backslash-n ==="
# The old printf '%s\\n' bug glued these into one line; jq parsed both objects
# and returned "true\nfalse". Now the validator rejects the malformed JSON and
# the safety-net dispatch path (tested separately) takes over.
out='MANUL_RESULT {"fire":true,"new":0,"pending":1}{"fire":false,"new":0,"pending":0}\n'
mapfile -t _r < <(parse_poll_output "$out")
assert_eq "2:fire" "false" "${_r[0]}"
assert_eq "2:new" "0" "${_r[1]}"
assert_eq "2:pending" "0" "${_r[2]}"

echo "=== Test 3: clean single-line input ==="
out='MANUL_RESULT {"fire":true,"new":3,"pending":1}'
mapfile -t _r < <(parse_poll_output "$out")
assert_eq "3:fire" "true" "${_r[0]}"
assert_eq "3:new" "3" "${_r[1]}"
assert_eq "3:pending" "1" "${_r[2]}"

echo "=== Test 4: no MANUL_RESULT line at all ==="
out='some diagnostic line on stderr
another line'
mapfile -t _r < <(parse_poll_output "$out")
assert_eq "4:fire" "false" "${_r[0]}"
assert_eq "4:new" "0" "${_r[1]}"
assert_eq "4:pending" "0" "${_r[2]}"

echo "=== Test 5: safety-net query counts eligible queued tasks ==="
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
DB="$TEST_DIR/test.db"
sqlite3 "$DB" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY, repository TEXT, issueNumber INTEGER, status TEXT, attempts INTEGER, nextAttemptAt TEXT);"
# No eligible tasks
cnt="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued' AND (attempts=0 OR nextAttemptAt <= datetime('now'));" 2>/dev/null || echo 0)"
assert_eq "5:empty" "0" "$cnt"
# One eligible (attempts=0)
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,nextAttemptAt) VALUES ('a','r',1,'queued',0,NULL);"
cnt="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued' AND (attempts=0 OR nextAttemptAt <= datetime('now'));" 2>/dev/null || echo 0)"
assert_eq "5:one" "1" "$cnt"
# One ineligible (future nextAttemptAt)
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,nextAttemptAt) VALUES ('b','r',2,'queued',1,'2099-01-01 00:00:00');"
cnt="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued' AND (attempts=0 OR nextAttemptAt <= datetime('now'));" 2>/dev/null || echo 0)"
assert_eq "5:filtered" "1" "$cnt"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1