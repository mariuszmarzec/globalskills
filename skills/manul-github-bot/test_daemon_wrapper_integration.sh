#!/bin/bash
# test_daemon_wrapper_integration.sh - Integration test for evaluate_task_completion()
# Tests the production completion decision function directly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create a temporary directory for test files
TEST_TMPDIR="${DEBUG_TMPDIR:-$(mktemp -d)}"
# Keep tmpdir for debugging when DEBUG_TEST=1 or DEBUG_TMPDIR is set
trap "if [ \"${DEBUG_TEST:-0}\" != \"1\" ] && [ -z \"${DEBUG_TMPDIR:-}\" ]; then rm -rf $TEST_TMPDIR; fi" EXIT
echo "TEST_TMPDIR=$TEST_TMPDIR" >&2

# Create fake executables for external dependencies
FAKE_BIN="$TEST_TMPDIR/fake_bin"
mkdir -p "$FAKE_BIN"

# Fake gh executable for GitHub API mocking
FAKE_GH="$FAKE_BIN/gh"
cat > "$FAKE_GH" << 'GH_EOF'
#!/bin/bash
# Fake gh: handles api (result-comment verification), pr list (PR existence),
# and pr create (auto-PR creation). No real PRs exist in tests, so the daemon
# must auto-create one for the autoCreatePr path to succeed.
if [[ "$1" == "api" ]]; then
    has_jq=false
    for arg in "$@"; do
        if [[ "$arg" == "--jq" ]]; then
            has_jq=true
            break
        fi
    done
    for arg in "$@"; do
        if [[ "$arg" == repos/* ]]; then
            path="$arg"
            path="${path#repos/}"
            remainder="${path#*/issues/}"
            remainder="${remainder#*/}"
            if [[ "$remainder" == "comments" ]]; then
                # Extract issue number from path like test/repo/issues/42/comments
                issue_num="${path#*/issues/}"
                issue_num="${issue_num%%/*}"
                case "$issue_num" in
                    42)
                        # Test A: valid result for COMMENT_1
                        json_output='[{"id":1001,"body":"<!-- manul-task:COMMENT_1:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    43)
                        # Test B: no result comment (missing result)
                        json_output='[]'
                        ;;
                    44)
                        # Test C: unrelated result (COMMENT_1, not COMMENT_3)
                        json_output='[{"id":1001,"body":"<!-- manul-task:COMMENT_1:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    45)
                        # Test D: valid result for COMMENT_4 (but no TASK_DONE in stdout)
                        json_output='[{"id":1004,"body":"<!-- manul-task:COMMENT_4:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    46|47)
                        # Tests E/F: rc!=0, verification skipped; return anything
                        json_output='[{"id":1005,"body":"<!-- manul-task:COMMENT_5:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    48)
                        # Test G: agent pushed branch + /compare URL, daemon auto-creates PR
                        json_output='[{"id":1007,"body":"<!-- manul-task:COMMENT_G:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    49)
                        # Test H: autoCreatePr disabled, no PR -> task fails
                        json_output='[{"id":1008,"body":"<!-- manul-task:COMMENT_H:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    50)
                        # Test I: agent left on default branch -> verify_required_pr must fail
                        json_output='[{"id":1009,"body":"<!-- manul-task:COMMENT_I:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    51)
                        # Test J: agent on real task branch -> verify_required_pr accepts
                        json_output='[{"id":1010,"body":"<!-- manul-task:COMMENT_J:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    52)
                        # Test K: informational task makes no repository changes; PR/branch is not required
                        json_output='[{"id":1011,"body":"<!-- manul-task:COMMENT_K:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    *)
                        json_output='[]'
                        ;;
                esac
                if [[ "$has_jq" == "true" ]]; then
                    echo "$json_output" | jq -r '.[] | select(.in_reply_to_id == null) | .body // ""'
                else
                    echo "$json_output"
                fi
                exit 0
            fi
        fi
    done
fi
# gh pr list: no PRs exist in tests (empty array)
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    echo '[]'
    exit 0
fi
# gh pr create: synthesize a PR URL
if [[ "$1" == "pr" && "$2" == "create" ]]; then
    echo "https://github.com/test/repo/pull/999"
    exit 0
fi
if [[ "$has_jq" == "true" ]]; then
    echo '[]'
else
    echo '{}'
fi
GH_EOF
chmod +x "$FAKE_GH"

# Source manul-daemon.sh with testing guard enabled.
# MANUL_DIR MUST be the tmpdir: poll.sh creates the real schema (25 columns) at
# $MANUL_DIR/manul.db on source, and the daemon's LOG/DB/CONFIG all derive from it.
MANUL_DIR="$TEST_TMPDIR/manul"
mkdir -p "$MANUL_DIR"
MANUL_TESTING=true source "$SCRIPT_DIR/manul-daemon.sh"
export PATH="$FAKE_BIN:$PATH"

# Setup test environment
LOG_FILE="$TEST_TMPDIR/daemon.log"
LIFECYCLE_LOG="$TEST_TMPDIR/lifecycle.log"
PID_FILE="$TEST_TMPDIR/daemon.pid"
DB="$TEST_TMPDIR/manul_test.db"
HEARTBEAT_INTERVAL=60
LOG="$LOG_FILE"
LIFECYCLE_LOG="$LIFECYCLE_LOG"
export PID_FILE DB HEARTBEAT_INTERVAL LOG LIFECYCLE_LOG CONFIG="$SCRIPT_DIR/config.json" MANUL_DIR

# DEFAULT_BRANCH is a global set by the production dispatch path; tests must set it.
DEFAULT_BRANCH="master"

# Real git workdir so verify_required_pr can resolve the task branch and (when
# autoCreatePr is enabled) auto-create a PR. The daemon's autoCreatePr path
# pushes/creates a PR from the checked-out branch.
WORKDIR="$TEST_TMPDIR/workdir"
mkdir -p "$WORKDIR"
git -C "$WORKDIR" init -q
git -C "$WORKDIR" config user.email test@example.com
git -C "$WORKDIR" config user.name test
printf 'test\n' >"$WORKDIR/README.md"
git -C "$WORKDIR" add README.md
git -C "$WORKDIR" commit -qm initial
INITIAL_HEAD_A="$(git -C "$WORKDIR" rev-parse HEAD)"
git -C "$WORKDIR" checkout -qb manul-task-COMMENT_1
echo "implementation change" >> "$WORKDIR/README.md"
git -C "$WORKDIR" add README.md
git -C "$WORKDIR" commit -qm "implementation change"

# Create test database with the SAME 25-column schema as poll.sh's real DB so
# update_task_completion() (which sets heartbeatAt/leaseExpiresAt) and
# verify_required_pr() (which reads action/prNumber/prUrl) operate on columns
# that actually exist.
sqlite3 "$DB" "CREATE TABLE processed_comments (
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
    nextAttemptAt TEXT,
    conversationId TEXT,
    parentTaskId TEXT,
    workspaceId TEXT,
    resultSummary TEXT,
    resultJson TEXT,
    baseId TEXT,
    action TEXT DEFAULT 'IMPLEMENT',
    prNumber INTEGER,
    prUrl TEXT
);"
# workerPid must match the test process PID ($$) so the completion path's
# ownership check (WHERE ... AND workerPid=$$) succeeds. The production
# claim path sets workerPid to the worker PID; the test inserts rows directly.
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_1','test/repo',42,'https://github.com/test/repo/issues/42#issuecomment-1001','user','test','task','queued',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_2','test/repo',43,'https://github.com/test/repo/issues/43#issuecomment-1002','user','test','task','queued',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_3','test/repo',44,'https://github.com/test/repo/issues/44#issuecomment-1003','user','test','task','queued',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_4','test/repo',45,'https://github.com/test/repo/issues/45#issuecomment-1004','user','test','task','queued',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_5','test/repo',46,'https://github.com/test/repo/issues/46#issuecomment-1005','user','test','task','queued',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_6','test/repo',47,'https://github.com/test/repo/issues/47#issuecomment-1006','user','test','task','queued',1,$$);;"
echo "0" > "$PID_FILE"

# ─── Test A: rc=0 + TASK_DONE + valid result comment -> COMPLETION_SUCCESS=true ─
echo "=== Test A: rc=0 + TASK_DONE + valid result -> COMPLETION_SUCCESS=true ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutA.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "42" "COMMENT_1" "COMMENT_1" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR" "" "$INITIAL_HEAD_A" "manul-task-COMMENT_1" "master"
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: Test A - expected COMPLETION_SUCCESS=true, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if [ -z "$FINAL_COMMENT" ]; then
    echo "FAIL: Test A - expected non-empty FINAL_COMMENT"
    exit 1
fi
echo "[OK] Test A: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test B: rc=0 + TASK_DONE + missing result comment -> COMPLETION_SUCCESS=false ─
echo "=== Test B: rc=0 + TASK_DONE + missing result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutB.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "43" "COMMENT_2" "COMMENT_2" "1" "0" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test B - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if [ -z "$FAIL_REASON" ]; then
    echo "FAIL: Test B - expected non-empty FAIL_REASON"
    exit 1
fi
echo "[OK] Test B: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test C: rc=0 + TASK_DONE + invalid/unrelated result -> COMPLETION_SUCCESS=false ─
echo "=== Test C: rc=0 + TASK_DONE + unrelated result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutC.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
echo "some unrelated output" >> "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "44" "COMMENT_3" "COMMENT_3" "1" "0" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test C - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test C: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false ─
echo "=== Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutD.txt"
echo "some output without marker" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "45" "COMMENT_4" "COMMENT_4" "1" "0" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test D - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test D: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false ─
echo "=== Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutE.txt"
echo "TASK_FAILED: orchestration error" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "46" "COMMENT_5" "COMMENT_5" "1" "42" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test E - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
# When rc!=0, FAIL_REASON may or may not be set depending on implementation
echo "[OK] Test E: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test F: timeout/signal + no TASK_DONE -> COMPLETION_SUCCESS=false ─
echo "=== Test F: non-zero rc + no TASK_DONE -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutF.txt"
echo "timeout occurred" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "47" "COMMENT_6" "COMMENT_6" "1" "124" "$STDOUT_FILE" "$DB" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test F - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test F: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test G: agent pushed branch + returned /compare/... URL (no PR) ─────────
# The exact problem case from shoppingListGenerator#28: the agent committed,
# pushed its branch, and returned a /compare/... "create PR" link instead of an
# actual PR. With autoCreatePr enabled the daemon must create the PR itself so
# the task succeeds instead of failing.
echo ""
echo "=== Test G: agent pushed branch + /compare URL, daemon auto-creates PR -> COMPLETION_SUCCESS=true ==="
# The fake gh returns NO pr list results (no PR exists) but a successful
# pr create (synthesized PR URL). The workdir is checked out on the task branch.
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_G';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_G','test/repo',48,'https://github.com/test/repo/issues/48#issuecomment-1007','user','test','task','queued',1,$$,'IMPLEMENT');" 2>/dev/null

WORKDIR_G="$TEST_TMPDIR/workdir-g"
mkdir -p "$WORKDIR_G"
git -C "$WORKDIR_G" init -q
git -C "$WORKDIR_G" config user.email test@example.com
git -C "$WORKDIR_G" config user.name test
printf 'test\n' >"$WORKDIR_G/README.md"
git -C "$WORKDIR_G" add README.md
git -C "$WORKDIR_G" commit -qm initial
INITIAL_HEAD_G="$(git -C "$WORKDIR_G" rev-parse HEAD)"
git -C "$WORKDIR_G" checkout -qb manul-task-COMMENT_G
echo "implementation change" >> "$WORKDIR_G/README.md"
git -C "$WORKDIR_G" add README.md
git -C "$WORKDIR_G" commit -qm "implementation change"

STDOUT_FILE="$TEST_TMPDIR/stdoutG.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "48" "COMMENT_G" "COMMENT_G" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_G" "" "$INITIAL_HEAD_G" "manul-task-COMMENT_G" "master"
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: Test G - expected COMPLETION_SUCCESS=true (daemon should auto-create PR), got '$COMPLETION_SUCCESS'"
    exit 1
fi
if [ -n "$FAIL_REASON" ]; then
    echo "FAIL: Test G - expected empty FAIL_REASON on success, got '$FAIL_REASON'"
    exit 1
fi
# Confirm the daemon actually invoked gh pr create (not just gh pr list)
if ! grep -q "pr_auto_create\|gh pr create" "$LOG_FILE" 2>/dev/null; then
    echo "FAIL: Test G - expected daemon to invoke gh pr create"
    exit 1
fi
echo "[OK] Test G: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test H: autoCreatePr disabled + no PR -> task fails ──────────────────────
# When autoCreatePr is false, a missing PR must still fail the task (no masking).
echo ""
echo "=== Test H: autoCreatePr disabled + no PR -> COMPLETION_SUCCESS=false ==="
CONFIG_DISABLED="$TEST_TMPDIR/config-disabled.json"
jq '.autoCreatePr = false' "$SCRIPT_DIR/config.json" > "$CONFIG_DISABLED"
export CONFIG="$CONFIG_DISABLED"

sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_H';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_H','test/repo',49,'https://github.com/test/repo/issues/49#issuecomment-1008','user','test','task','queued',1,$$,'IMPLEMENT');" 2>/dev/null

WORKDIR_H="$TEST_TMPDIR/workdir-h"
mkdir -p "$WORKDIR_H"
git -C "$WORKDIR_H" init -q
git -C "$WORKDIR_H" config user.email test@example.com
git -C "$WORKDIR_H" config user.name test
printf 'test\n' >"$WORKDIR_H/README.md"
git -C "$WORKDIR_H" add README.md
git -C "$WORKDIR_H" commit -qm initial
INITIAL_HEAD_H="$(git -C "$WORKDIR_H" rev-parse HEAD)"
git -C "$WORKDIR_H" checkout -qb manul-task-COMMENT_H
echo "implementation change" >> "$WORKDIR_H/README.md"
git -C "$WORKDIR_H" add README.md
git -C "$WORKDIR_H" commit -qm "implementation change"

STDOUT_FILE="$TEST_TMPDIR/stdoutH.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "49" "COMMENT_H" "COMMENT_H" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_H" "" "$INITIAL_HEAD_H" "manul-task-COMMENT_H" "master"
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test H - expected COMPLETION_SUCCESS=false when autoCreatePr disabled, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if ! printf '%s' "$FAIL_REASON" | grep -q "did not produce a real PR"; then
    echo "FAIL: Test H - expected FAIL_REASON about missing PR, got '$FAIL_REASON'"
    exit 1
fi
if ! grep -q "MISSING_PR\|no PR found" "$LOG_FILE" 2>/dev/null; then
    echo "FAIL: Test H - expected MISSING_PR log entry (no PR, autoCreatePr disabled)"
    exit 1
fi
# Restore the canonical config for any remaining tests
export CONFIG="$SCRIPT_DIR/config.json"
echo "[OK] Test H: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test I: issue task left on default branch -> verify_required_pr must FAIL ─
# Regression for the branch-lifecycle contract: Manul owns branch creation for
# standalone (issue) tasks. If the checked-out branch is the default branch,
# verify_required_pr() must reject the task rather than silently accept it.
echo ""
echo "=== Test I: agent left on default branch -> verify_required_pr fails ==="
WORKDIR_I="$TEST_TMPDIR/workdir-i"
mkdir -p "$WORKDIR_I"
git -C "$WORKDIR_I" init -q
git -C "$WORKDIR_I" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_I" config user.email test@example.com
git -C "$WORKDIR_I" config user.name test
printf 'test\n' >"$WORKDIR_I/README.md"
git -C "$WORKDIR_I" add README.md
git -C "$WORKDIR_I" commit -qm initial
# Intentionally stay on the default branch (agent did NOT create a task branch)
git -C "$WORKDIR_I" checkout -q master
INITIAL_HEAD_I="$(git -C "$WORKDIR_I" rev-parse HEAD)"
echo "forbidden direct base change" >> "$WORKDIR_I/README.md"
git -C "$WORKDIR_I" add README.md
git -C "$WORKDIR_I" commit -qm "forbidden direct base change"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_I';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_I','test/repo',50,'https://github.com/test/repo/issues/50#issuecomment-1009','user','test','task','queued',1,$$,'IMPLEMENT');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutI.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "50" "COMMENT_I" "COMMENT_I" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_I" "" "$INITIAL_HEAD_I" "master" "master"
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test I - expected COMPLETION_SUCCESS=false when checked-out branch is the default branch, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if ! printf '%s' "$FAIL_REASON" | grep -q "did not produce a real PR"; then
    echo "FAIL: Test I - expected FAIL_REASON about missing PR, got '$FAIL_REASON'"
    exit 1
fi
if ! grep -q "invalid_task_branch\|MISSING_PR\|no PR found" "$LOG_FILE" 2>/dev/null; then
    echo "FAIL: Test I - expected verify_required_pr to log invalid_task_branch / MISSING_PR"
    exit 1
fi
echo "[OK] Test I: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test J: agent on a real task branch with autoCreatePr -> verify_required_pr accepts ─
# Confirms the positive half of the contract: a dedicated task branch (not the
# default) is accepted by verify_required_pr when autoCreatePr can create the PR.
echo ""
echo "=== Test J: agent on task branch + autoCreatePr -> verify_required_pr accepts ==="
WORKDIR_J="$TEST_TMPDIR/workdir-j"
mkdir -p "$WORKDIR_J"
git -C "$WORKDIR_J" init -q
git -C "$WORKDIR_J" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_J" config user.email test@example.com
git -C "$WORKDIR_J" config user.name test
printf 'test\n' >"$WORKDIR_J/README.md"
git -C "$WORKDIR_J" add README.md
git -C "$WORKDIR_J" commit -qm initial
INITIAL_HEAD_J="$(git -C "$WORKDIR_J" rev-parse HEAD)"
git -C "$WORKDIR_J" checkout -qb manul-task-COMMENT_J
echo "implementation change" >> "$WORKDIR_J/README.md"
git -C "$WORKDIR_J" add README.md
git -C "$WORKDIR_J" commit -qm "implementation change"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_J';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_J','test/repo',51,'https://github.com/test/repo/issues/51#issuecomment-1010','user','test','task','queued',1,$$,'IMPLEMENT');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutJ.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "51" "COMMENT_J" "COMMENT_J" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_J" "" "$INITIAL_HEAD_J" "manul-task-COMMENT_J" "master"
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: Test J - expected COMPLETION_SUCCESS=true on a real task branch, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test J: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test K: informational task with no repo changes -> success without PR ─
echo ""
echo "=== Test K: informational task + no repository changes -> COMPLETION_SUCCESS=true ==="
WORKDIR_K="$TEST_TMPDIR/workdir-k"
mkdir -p "$WORKDIR_K"
git -C "$WORKDIR_K" init -q
git -C "$WORKDIR_K" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_K" config user.email test@example.com
git -C "$WORKDIR_K" config user.name test
printf "test\n" >"$WORKDIR_K/README.md"
git -C "$WORKDIR_K" add README.md
git -C "$WORKDIR_K" commit -qm initial
INITIAL_HEAD_K="$(git -C "$WORKDIR_K" rev-parse HEAD)"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_K';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_K','test/repo',52,'https://github.com/test/repo/issues/52#issuecomment-1011','user','test','answer question','queued',1,$$,'IMPLEMENT');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutK.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "52" "COMMENT_K" "COMMENT_K" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_K" "" "$INITIAL_HEAD_K" "master" "master"
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: Test K - expected informational task with no repo changes to succeed, got $COMPLETION_SUCCESS ($FAIL_REASON)"
    exit 1
fi
if printf "%s" "$FAIL_REASON" | grep -q "real PR"; then
    echo "FAIL: Test K - informational task should not require a PR"
    exit 1
fi
echo "[OK] Test K: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test L: verified PR metadata must replace the issue number ───────────────
# Regression for issue-task feedback: queue ingestion may initialize prNumber
# with the issue number, but once the daemon verifies the real PR it must store
# the actual PR number/URL before TASK_DONE feedback is emitted.
echo ""
echo "=== Test L: verified PR metadata replaces issue number ==="
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_L';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,prNumber,prUrl) VALUES ('COMMENT_L','test/repo',53,'https://github.com/test/repo/issues/53#issuecomment-1012','user','test','task','completed',1,$,53,NULL);" 2>/dev/null
if ! persist_verified_pr_metadata "COMMENT_L" "37" "https://github.com/test/repo/pull/37"; then
    echo "FAIL: Test L - persist_verified_pr_metadata returned failure"
    exit 1
fi
actual_pr="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='COMMENT_L';")"
actual_url="$(sqlite3 "$DB" "SELECT prUrl FROM processed_comments WHERE commentId='COMMENT_L';")"
if [ "$actual_pr" != "37" ]; then
    echo "FAIL: Test L - expected prNumber=37, got '$actual_pr'"
    exit 1
fi
if [ "$actual_url" != "https://github.com/test/repo/pull/37" ]; then
    echo "FAIL: Test L - expected canonical PR URL, got '$actual_url'"
    exit 1
fi
echo "[OK] Test L: PASSED (issue number replaced with verified PR #37)"

# ─── Test M: issuebody task with repository changes must require a real PR ──
echo ""
echo "=== Test M: issuebody task with repository changes requires real PR ==="
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_M';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action,prNumber) VALUES ('issuebody:COMMENT_M','test/repo',54,'https://github.com/test/repo/issues/54','user','test','task','queued',1,$,'IMPLEMENT',54);" 2>/dev/null

WORKDIR_M="$TEST_TMPDIR/workdir-m"
mkdir -p "$WORKDIR_M"
git -C "$WORKDIR_M" init -q
git -C "$WORKDIR_M" config user.email test@example.com
git -C "$WORKDIR_M" config user.name test
printf 'test\n' >"$WORKDIR_M/README.md"
git -C "$WORKDIR_M" add README.md
git -C "$WORKDIR_M" commit -qm initial
INITIAL_HEAD_M="$(git -C "$WORKDIR_M" rev-parse HEAD)"
git -C "$WORKDIR_M" checkout -qb manul-task-COMMENT_M
echo "implementation change" >>"$WORKDIR_M/README.md"
git -C "$WORKDIR_M" add README.md
git -C "$WORKDIR_M" commit -qm "implementation change"

STDOUT_FILE="$TEST_TMPDIR/stdoutM.txt"
echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "54" "issuebody:COMMENT_M" "issuebody:COMMENT_M" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_M" "" "$INITIAL_HEAD_M" "manul-task-COMMENT_M" "master"
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test M - issuebody task with repository changes must not succeed without a real PR"
    exit 1
fi
if ! printf '%s' "$FAIL_REASON" | grep -q "real PR"; then
    echo "FAIL: Test M - expected missing real PR failure, got '$FAIL_REASON'"
    exit 1
fi
echo "[OK] Test M: PASSED (issuebody repository change cannot bypass PR verification)"

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "=== INTEGRATION TEST SUMMARY ==="
echo "[OK] Test A: rc=0 + TASK_DONE + valid result -> COMPLETION_SUCCESS=true"
echo "[OK] Test B: rc=0 + TASK_DONE + missing result -> COMPLETION_SUCCESS=false"
echo "[OK] Test C: rc=0 + TASK_DONE + unrelated result -> COMPLETION_SUCCESS=false"
echo "[OK] Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false"
echo "[OK] Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false"
echo "[OK] Test F: non-zero rc + no TASK_DONE -> COMPLETION_SUCCESS=false"
echo "[OK] Test G: agent pushed branch + /compare URL, daemon auto-creates PR -> COMPLETION_SUCCESS=true"
echo "[OK] Test H: autoCreatePr disabled + no PR -> COMPLETION_SUCCESS=false"
echo "[OK] Test I: agent left on default branch -> verify_required_pr FAILS (regression)"
echo "[OK] Test J: agent on real task branch -> verify_required_pr ACCEPTS"
echo "[OK] All tests call real evaluate_task_completion() from manul-daemon.sh"
echo "=== ALL INTEGRATION TESTS PASSED ==="
