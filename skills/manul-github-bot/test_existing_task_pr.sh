#!/usr/bin/env bash
# Regression tests for already-satisfied IMPLEMENT retries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MANUL_DIR="$TMP/manul"
mkdir -p "$MANUL_DIR"
cat >"$MANUL_DIR/config.json" <<'JSON'
{"automation":{"heartbeatInterval":60,"heartbeatTimeout":900,"leaseTimeout":900,"maxAttemptsBeforeFail":3,"lockTtl":1800}}
JSON
# Isolate the production verifier without starting the daemon CLI loop.
# Extract the actual function body from manul-daemon.sh so the regression test
# exercises production logic while keeping runtime bootstrap outside the fixture.
DB="$TMP/processed-comments.sqlite"
LOG="$TMP/daemon.log"
LIFECYCLE_LOG="$TMP/lifecycle.log"
CONFIG="$SCRIPT_DIR/config.json"
GH_API_TIMEOUT=5
export DB LOG LIFECYCLE_LOG CONFIG GH_API_TIMEOUT
mkdir -p "$(dirname "$DB")"
: >"$LOG"
: >"$LIFECYCLE_LOG"

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}
log() { echo "$*" >>"$LOG"; }
lc_log() { echo "$*" >>"$LIFECYCLE_LOG"; }

verifier_source="$(sed -n '/^verify_existing_task_pr() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
if [ -z "$verifier_source" ]; then
  echo "FAIL: verify_existing_task_pr() was not found in manul-daemon.sh" >&2
  exit 1
fi
eval "$verifier_source"

sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  status TEXT NOT NULL,
  action TEXT,
  prUrl TEXT
);
SQL

# Build a clean base checkout and a feature branch that is pushed to origin.
WORKDIR="$TMP/workdir"
ORIGIN="$TMP/origin.git"
mkdir -p "$WORKDIR"
git init --quiet --initial-branch=main "$WORKDIR"
git -C "$WORKDIR" config user.name test
git -C "$WORKDIR" config user.email test@example.com
printf 'base\n' >"$WORKDIR/README.md"
git -C "$WORKDIR" add README.md
git -C "$WORKDIR" commit -qm "initial base"
INITIAL_BASE_SHA="$(git -C "$WORKDIR" rev-parse HEAD)"
git init --quiet --bare "$ORIGIN"
git -C "$WORKDIR" remote add origin "$ORIGIN"
git -C "$WORKDIR" push -q --set-upstream origin main
git -C "$WORKDIR" checkout -qb feature/17-helloworld-java
printf 'class HelloWorld {}\n' >"$WORKDIR/helloworld.java"
git -C "$WORKDIR" add helloworld.java
git -C "$WORKDIR" commit -qm "Add HelloWorld"
PR_HEAD_SHA="$(git -C "$WORKDIR" rev-parse HEAD)"
git -C "$WORKDIR" push -q --set-upstream origin feature/17-helloworld-java
git -C "$WORKDIR" checkout -q main

# Fake GitHub's PR-list response while using real Git and SQLite checks.
# Set all helper globals normally supplied by the daemon's dispatch path.
DEFAULT_BRANCH="main"
MANUL_TESTING=true

export FAKE_GH_PR_LIST="$TMP/pr-list.json"
cat >"$TMP/bin-gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  cat "$FAKE_GH_PR_LIST"
  exit 0
fi
echo "unexpected gh command: $*" >&2
exit 2
MOCK
chmod +x "$TMP/bin-gh"
mkdir -p "$TMP/bin"
mv "$TMP/bin-gh" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

PR_URL="https://github.com/test/repo/pull/18"
PREVIOUS_TASK="issuebody:5816053678"
CURRENT_TASK="issue:6127115709"
write_pr_fixture() {
  local base="${1:-main}" head_sha="${2:-$PR_HEAD_SHA}" body_task="${3:-$PREVIOUS_TASK}"
  jq -cn --arg url "$PR_URL" --arg base "$base" \
    --arg head "feature/17-helloworld-java" --arg sha "$head_sha" \
    --arg body "Automatically created by Manul for task $body_task." \
    '[{number:18,url:$url,state:"OPEN",baseRefName:$base,headRefName:$head,headRefOid:$sha,body:$body}]' \
    >"$FAKE_GH_PR_LIST"
}

# Historical issuebody rows can contain the GitHub object ID in issueNumber;
# the human issue number must be derived from commentUrl.
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,action,prUrl) VALUES ('$PREVIOUS_TASK','test/repo',5816053678,'https://github.com/test/repo/issues/17','completed','IMPLEMENT','$PR_URL');"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,action,prUrl) VALUES ('$CURRENT_TASK','test/repo',17,'https://github.com/test/repo/issues/17#issuecomment-6127115709','running','IMPLEMENT',NULL);"

# Case 1: the workspace is back on main, but the same issue has a previous
# completed task with a verified PR URL and the PR head still matches origin.
write_pr_fixture
VERIFIED_EXISTING_PR_BRANCH=""
VERIFIED_EXISTING_PR_URL=""
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  [ "$VERIFIED_EXISTING_PR_BRANCH" = "feature/17-helloworld-java" ]
  [ "$VERIFIED_EXISTING_PR_URL" = "$PR_URL" ]
  echo "PASS: accepts existing PR verified for a completed task on the same issue"
else
  echo "FAIL: expected the previously verified same-issue PR to qualify" >&2
  exit 1
fi

# Case 2: don't accept a PR if its head SHA no longer matches the remote branch.
write_pr_fixture "main" "0000000000000000000000000000000000000000"
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  echo "FAIL: accepted PR whose head SHA does not match origin" >&2
  exit 1
else
  echo "PASS: rejects a stale/mismatched remote PR head"
fi

# Case 3: a PR targeting the wrong base cannot satisfy the task.
write_pr_fixture "develop" "$PR_HEAD_SHA"
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  echo "FAIL: accepted a PR targeting the wrong base branch" >&2
  exit 1
else
  echo "PASS: rejects a PR targeting the wrong base"
fi

# Case 4: a task with no same-issue completed PR and no exact task ID in its
# PR body must fail closed.
sqlite3 "$DB" "UPDATE processed_comments SET status='failed' WHERE commentId='$PREVIOUS_TASK';"
write_pr_fixture
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  echo "FAIL: accepted a PR without valid current/prior-task correlation" >&2
  exit 1
else
  echo "PASS: rejects unrelated or non-completed prior task evidence"
fi

# Case 5: a fresh task explicitly named in the PR body can pass without a prior
# completed task, provided base and remote head checks still pass.
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='$PREVIOUS_TASK';"
write_pr_fixture "main" "$PR_HEAD_SHA" "$CURRENT_TASK"
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  echo "PASS: accepts PR explicitly correlated to the current task"
else
  echo "FAIL: expected explicitly task-bound PR to qualify" >&2
  exit 1
fi

# Assert that the real IMPLEMENT evaluator has a no-op path guarded by the
# verifier, skips ordinary branch/PR verification after it qualifies, and still
# validates the canonical PR URL before declaring success.
evaluator_block="$(sed -n '/elif \\[ "\\$TASK_ACTION" = "IMPLEMENT" \\]; then/,+42p' "$SCRIPT_DIR/manul-daemon.sh")"
grep -q 'verify_existing_task_pr' <<<"$evaluator_block"
grep -q 'already_satisfied="true"' <<<"$evaluator_block"
grep -q 'already_satisfied" != "true"' <<<"$evaluator_block"
grep -q 'verify_result_comment_pr_url' <<<"$evaluator_block"
echo "PASS: IMPLEMENT evaluator verifies an existing PR and retains canonical URL validation"

echo "All existing-task PR regression tests passed."
