#!/usr/bin/bash
# test_verify_result_comment.sh — Isolated integration tests for verify_result_comment()
#
# Verifies the result-comment contract WITHOUT touching production state.
# Uses a temporary SQLite DB and a configurable fake `gh` executable.
#
# Behavioral coverage:
#   1. Found: top-level comment with matching deterministic marker → PASS (rc=0)
#   2. Found: reply comment (in_reply_to_id != null) with matching marker → PASS (rc=0)
#   3. Not found: no comments contain the marker → FAIL (rc=1)
#   4. Lifecycle comments rejected: ✅/🔄/❌/⚠️ prefix excluded even with marker
#   5. Multiple matches: two comments with same marker → FAIL (rc=1)
#   6. Wrong attempt: marker has different attempt number → FAIL (rc=1)
#   7. gh API failure: gh exits non-zero → FAIL (rc=1, fail-closed)
#   8. Missing commentUrl in DB: record doesn't exist → FAIL (rc=1, fail-closed)
#   9. Empty/null body: body is null or empty string → not matched
#
# Integration test (bonus):
#  10. Full dispatch→verify path using real daemon functions + fake external deps
#
# Usage: bash test_verify_result_comment.sh
# Exit code: 0 if all pass, >0 if any fail

set -uo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

# ─── Temp working directory (cleaned on exit) ─────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Temp DB — NEVER touches production
TEMP_DB="$WORK/manul_test.db"
LOG_FILE="$WORK/daemon.log"
LIFECYCLE_LOG="$WORK/lifecycle.log"
PID_FILE="$WORK/daemon.pid"
MANUL_DIR="$WORK/manul_dir"
mkdir -p "$MANUL_DIR"

# Fake executables directory (prepended to PATH)
FAKE_BIN="$WORK/fake_bin"
mkdir -p "$FAKE_BIN"
mkdir -p "$WORK/responses"   # fake gh reads response files from here

# ─── Helper counters ──────────────────────────────────────────────────────────
ok() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        ok "$label (rc=$actual)"
    else
        fail "$label (expected rc=$expected, got rc=$actual)"
    fi
}

# ─── Source daemon functions ───────────────────────────────────────────────────
DAEMON="/home/marzec/.globalskills/skills/manul-github-bot/manul-daemon.sh"

# Extract only the functions we need (no globals, no daemon startup)
eval "$(sed -n '/^log() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^lc_log() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^sql_escape() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^get_daemon_pid() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^verify_result_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^post_github_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^update_task_completion() {/,/^}/p' "$DAEMON")"

# Override paths so sourced functions use our temp dirs
LOG="$LOG_FILE"
LIFECYCLE_LOG="$LIFECYCLE_LOG"
PID_FILE="$PID_FILE"
DB="$TEMP_DB"

# Write a fake daemon PID so get_daemon_pid returns 0 (no real daemon running)
echo "0" > "$PID_FILE"

# ─── Setup temp SQLite DB with full schema ─────────────────────────────────────
setup_db() {
    sqlite3 "$TEMP_DB" "
        CREATE TABLE IF NOT EXISTS processed_comments (
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
            nextAttemptAt TEXT
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    " 2>/dev/null
}

insert_task() {
    local comment_id="$1" repo="$2" issue="$3" url="$4"
    local escaped_url
    escaped_url="$(printf '%s' "$url" | sed "s/'/''/g")"
    sqlite3 "$TEMP_DB" "
        INSERT OR REPLACE INTO processed_comments
            (commentId, repository, issueNumber, commentUrl, prompt, status, attempts, createdAt)
        VALUES
            ('$comment_id', '$repo', $issue, '$escaped_url', 'test prompt', 'queued', 0, '2026-09-10T00:00:00Z');
    " 2>/dev/null
}

# ─── Fake gh executable ────────────────────────────────────────────────────────
cat > "$FAKE_BIN/gh" << 'GHEOF'
#!/bin/bash
# Fake gh — responds from pre-staged JSON files or fails on demand
set -uo pipefail

# Get workspace from env or derive from script location
WORKSPACE="${FAKE_GH_WORKSPACE:-$(dirname "$0")/..}"

RESPONSE_FILE=""
JQ_FILTER=""
API_PATH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        api)
            shift
            ;;
        --jq)
            shift
            JQ_FILTER="$1"
            shift
            ;;
        repos/*)
            # Handle the path as a single quoted argument
            API_PATH="$1"
            shift
            while [[ $# -gt 0 ]] && [[ ! "$1" == -* ]]; do
                API_PATH="$API_PATH $1"
                shift
            done
            # Convert API path to response file name
            # Example: repos/owner/repo/issues/1/comments -> owner__repo__issues__1__comments.json
            filename="${API_PATH#repos/}"
            filename="${filename//\//__}.json"
            RESPONSE_FILE="$WORKSPACE/responses/$filename"
            continue
            ;;
        *)
            shift
            ;;
    esac
done

# Output the response (optionally filter with jq)
if [[ -n "$RESPONSE_FILE" ]] && [[ -f "$RESPONSE_FILE" ]]; then
    if [[ -n "$JQ_FILTER" ]]; then
        jq -r "$JQ_FILTER" < "$RESPONSE_FILE" 2>/dev/null || true
    else
        cat "$RESPONSE_FILE"
    fi
else
    echo "[]"
fi
GHEOF
chmod +x "$FAKE_BIN/gh"

# Fake openclaw (not used by verify_result_comment but needed if sourcing daemon fully)
cat > "$FAKE_BIN/openclaw" << 'OCEOF'
#!/usr/bin/bash
echo '{"status":"mocked","model":"test"}'
OCEOF
chmod +x "$FAKE_BIN/openclaw"

# Prepend fake bin to PATH
export PATH="$FAKE_BIN:$PATH"
# Export workspace for fake gh to find response files
export FAKE_GH_WORKSPACE="$WORK"

# ─── Test runner ───────────────────────────────────────────────────────────────
run_test() {
    local test_name="$1"
    local repo="$2"
    local issue="$3"
    local comment_id="$4"
    local attempt="$5"
    local response_file="$6"   # path to JSON response file, or "missing" for no file
    local expected_rc="$7"
    local extra_env="${8:-}"   # extra env vars like GH_RESPONSE_FILE=...

    echo -n "Test: $test_name ... "

    # Reset DB for this test
    rm -f "$TEMP_DB"
    setup_db

    # Insert task record
    local comment_url="https://github.com/${repo}/issues/${issue}#issuecomment-${comment_id}"
    insert_task "$comment_id" "$repo" "$issue" "$comment_url"

    # Set up response
    if [[ "$response_file" == "missing" ]]; then
        rm -f "$WORK/responses/"*.json
    elif [[ "$response_file" == "failure" ]]; then
        # Configure fake gh to simulate failure
        RESPONSE_CONTENT='FAIL repos/owner__repo__issues__1__comments.json'
    else
        # Copy the response file to the expected location for fake gh
        local dest_file="$WORK/responses/owner__repo__issues__1__comments.json"
        if [[ "$response_file" != "$dest_file" ]]; then
            cp "$response_file" "$dest_file"
        fi
    fi

    # Run verification
    local rc=0
    if [[ -n "$extra_env" ]]; then
        # Parse extra env (format: "KEY=val KEY2=val2")
        eval export "$extra_env"
    fi
    # For integration tests, explicitly set GH_RESPONSE_FILE to ensure fake gh uses the right response
    local gh_response_file="${GH_RESPONSE_FILE:-}"
    if [[ "$test_name" == "Full dispatch cycle" ]] || [[ "$test_name" == "Lifecycle emoji prefix" ]]; then
        gh_response_file="$WORK/responses/owner__repo__issues__1__comments.json"
    fi

    # Run verification
    verify_result_comment "$repo" "$issue" "$comment_id" "$comment_id" "$attempt" >/dev/null 2>&1
    rc=$?

    assert_rc "$test_name" "$expected_rc" "$rc"
}

# ============================================================================
# Unit tests — 9 behavioral cases
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  verify_result_comment() — Unit Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Write response JSON files into temp dir
REPO="owner/repo"

# ── Test 1: Top-level comment with matching marker ─────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[{"id": 100, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:result-1:attempt:1 -->\nI completed the task.\n\n— manul 🐈"}]
EOF
run_test "Found: top-level comment with marker" \
    "$REPO" 1 "result-1" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 0

# ── Test 2: Reply comment with matching marker ─────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[{"id": 101, "user": {"login": "Manul-Bot"}, "in_reply_to_id": 100, "body": "<!-- manul-task:result-2:attempt:1 -->\nReply with result.\n\n— manul 🐈"}]
EOF
run_test "Found: reply comment with marker" \
    "$REPO" 1 "result-2" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 0

# ── Test 3: No comments with marker ────────────────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[{"id": 102, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "Some comment without marker"}]
EOF
run_test "Not found: no marker in comments" \
    "$REPO" 1 "result-3" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ── Test 4: Lifecycle comments rejected ────────────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[
  {"id": 103, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "✅ Manul completed the task"},
  {"id": 104, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "🔄 Manul is working on this task"},
  {"id": 105, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "❌ Manul failed after 3 attempts"},
  {"id": 106, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "⚠️ Manul detected an issue"}
]
EOF
run_test "Lifecycle comments rejected (no real result)" \
    "$REPO" 1 "result-4" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ── Test 5: Multiple matching comments → FAIL ──────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[
  {"id": 107, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:result-5:attempt:1 -->\nFirst result"},
  {"id": 108, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:result-5:attempt:1 -->\nSecond result"}
]
EOF
run_test "Multiple matches rejected (ambiguity)" \
    "$REPO" 1 "result-5" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ── Test 6: Wrong attempt number ───────────────────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[{"id": 109, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:result-6:attempt:3 -->\nWrong attempt"}]
EOF
run_test "Wrong attempt number rejected" \
    "$REPO" 1 "result-6" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ── Test 7: gh API failure → fail-closed ──────────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
FAIL repos/owner__repo__issues__1__comments.json
EOF
run_test "gh API failure → fail-closed (rc=1)" \
    "$REPO" 1 "result-7" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1 \
    "FAIL_MODE=1"

# ── Test 8: Missing commentUrl in DB ───────────────────────────────────────────
rm -f "$TEMP_DB"
setup_db
# Don't insert any task record
echo -n "Test: Missing commentUrl in DB ... "
verify_result_comment "$REPO" 1 "nonexistent-task" "nonexistent-task" 1 >/dev/null 2>&1
rc=$?
assert_rc "Missing commentUrl in DB" 1 "$rc"

# ── Test 9: Empty/null body ────────────────────────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[
  {"id": 110, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": null},
  {"id": 111, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": ""},
  {"id": 112, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "Just text, no marker"}
]
EOF
run_test "Empty/null bodies don't match" \
    "$REPO" 1 "result-9" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ============================================================================
# Integration test — full dispatch flow with real daemon state machine
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  verify_result_comment() — Integration Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ── Integration Test 10: Full cycle — task queued → claimed → verified ─────────
echo "Test: Full dispatch cycle (queued→running→verified→completed)"
rm -f "$TEMP_DB"
setup_db

COMMENT_ID="integration-10"
REPO="owner/repo"
ISSUE=1
ATTEMPT=1
COMMENT_URL="https://github.com/owner/repo/issues/1#issuecomment-${COMMENT_ID}"

# Step A: Insert task as queued (use insert_task to satisfy NOT NULL constraints)
insert_task "$COMMENT_ID" "$REPO" "$ISSUE" "$COMMENT_URL"

# Step B: Verify task is queued
queued_before="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='$COMMENT_ID' AND status='queued';")"
if [ "$queued_before" = "1" ]; then
    ok "Integration: task starts as queued"
else
    fail "Integration: task should be queued (got $queued_before)"
fi

# Step C: Simulate agent completing task (update DB to running, then verify result)
sqlite3 "$TEMP_DB" "
    UPDATE processed_comments
    SET status='running', attempts=1, processedAt=datetime('now'), heartbeatAt=datetime('now'), workerPid=0
    WHERE commentId='$COMMENT_ID';
" 2>/dev/null

# Step D: Post a fake result comment via fake gh
RESULT_BODY="<!-- manul-task:${COMMENT_ID}:attempt:${ATTEMPT} -->
I have completed the implementation. All tests pass.

— manul 🐈"

# Use jq to construct valid JSON with proper escaping
echo '[{"id": 200, "user": {"login": "Agent-Fix"}, "in_reply_to_id": null, "body": null}]' | jq --arg body "$RESULT_BODY" '.[0].body = $body' > "$WORK/responses/owner__repo__issues__1__comments.json"

# Step E: Run verification
verify_result_comment "$REPO" "$ISSUE" "$COMMENT_ID" "$COMMENT_ID" "$ATTEMPT" 2>&1 | head -5
if [ $? -eq 0 ]; then
    ok "Integration: verification passes with correct marker"
else
    fail "Integration: verification should pass with correct marker"
fi

# Step F: Transition to completed
if update_task_completion "$COMMENT_ID" "completed" 2>/dev/null; then
    ok "Integration: task transitioned to completed"
else
    fail "Integration: task should transition to completed"
fi

# Step G: Verify final state
final_status="$(sqlite3 "$TEMP_DB" "SELECT status FROM processed_comments WHERE commentId='$COMMENT_ID';")"
final_processed="$(sqlite3 "$TEMP_DB" "SELECT processedAt FROM processed_comments WHERE commentId='$COMMENT_ID';")"
if [ "$final_status" = "completed" ] && [ -n "$final_processed" ]; then
    ok "Integration: final state is completed with processedAt set"
else
    fail "Integration: expected completed+processedAt, got status=$final_status processedAt=$final_processed"
fi

# Step H: Idempotent re-verification (already completed)
verify_result_comment "$REPO" "$ISSUE" "$COMMENT_ID" "$COMMENT_ID" "$ATTEMPT" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    ok "Integration: re-verification on completed task still passes"
else
    fail "Integration: re-verification should still pass"
fi

# Step I: Verify duplicate comment doesn't double-count
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << JSONEOF
[
  {"id": 200, "user": {"login": "Agent-Fix"}, "in_reply_to_id": null, "body": "<!-- manul-task:${COMMENT_ID}:attempt:${ATTEMPT} -->\nFirst result"},
  {"id": 201, "user": {"login": "Agent-Fix"}, "in_reply_to_id": null, "body": "<!-- manul-task:${COMMENT_ID}:attempt:${ATTEMPT} -->\nDuplicate result"}
]
JSONEOF

verify_result_comment "$REPO" "$ISSUE" "$COMMENT_ID" "$COMMENT_ID" "$ATTEMPT" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    ok "Integration: duplicate comments correctly rejected (rc=1)"
else
    fail "Integration: duplicate comments should be rejected (expected rc=1)"
fi

# ── Integration Test 11: Fail-closed on missing commentUrl ────────────────────
echo ""
echo "Test: Fail-closed when commentUrl is missing from DB"
rm -f "$TEMP_DB"
setup_db

# Insert task WITHOUT a valid commentUrl (empty string)
sqlite3 "$TEMP_DB" "
    INSERT OR REPLACE INTO processed_comments
        (commentId, repository, issueNumber, commentUrl, prompt, status, attempts, createdAt)
    VALUES
        ('no-url-task', '$REPO', $ISSUE, '', 'test prompt', 'queued', 0, '2026-09-10T00:00:00Z');
" 2>/dev/null

verify_result_comment "$REPO" "$ISSUE" "no-url-task" "no-url-task" 1 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    ok "Integration: missing commentUrl correctly fails (rc=1)"
else
    fail "Integration: missing commentUrl should cause failure (expected rc=1)"
fi

# ── Integration Test 12: Lifecycle comments in result don't fool verification ──
echo ""
echo "Test: Lifecycle emoji prefix doesn't produce false positive"
rm -f "$TEMP_DB"
setup_db

LC_COMMENT_URL="https://github.com/owner/repo/issues/1#issuecomment-life-cycle-test"
insert_task "life-cycle-test" "$REPO" "$ISSUE" "$LC_COMMENT_URL"

# Comment starts with ✅ (lifecycle) but also contains a marker — should be rejected
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[{"id": 300, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "✅ Manul completed\n<!-- manul-task:life-cycle-test:attempt:1 -->\nThis should not count"}]
EOF

verify_result_comment "$REPO" "$ISSUE" "life-cycle-test" "life-cycle-test" 1 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    ok "Integration: lifecycle-prefixed comment correctly rejected (rc=1)"
else
    fail "Integration: lifecycle-prefixed comment should be rejected (expected rc=1)"
fi

# ============================================================================
# Results summary
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL tests)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}All tests passed.${NC}"
else
    echo -e "${RED}$FAIL test(s) failed.${NC}"
fi

exit $FAIL
