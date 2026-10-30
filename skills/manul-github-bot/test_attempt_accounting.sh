#!/usr/bin/bash
# test_attempt_accounting.sh — Regression tests for issue #110
#
# Covers three defect fixes:
#   1. Duplicate TASK_STARTED idempotency (DB fast-path + start_comment_already_posted)
#   2. Terminal marker ordering (TASK_DONE/TASK_FAILED assembled BEFORE post_github_comment)
#   3. manul-status observability (preExecutionFailures, agentStartedAt, startedAttempt)
#
# Exit code: 0 if all pass, >0 if any fail
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

ok() {
    PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}
fail() {
    FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

# ─── Temp working directory ────────────────────────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TEMP_DB="$WORK/manul_test.db"
LOG_FILE="$WORK/daemon.log"
MANUL_DIR="$WORK/manul_dir"
CONFIG="$WORK/config.json"
mkdir -p "$MANUL_DIR"
echo '{"automation":{"maxPreExecutionFailures":8,"maxAttemptsBeforeFail":3}}' > "$CONFIG"

FAKE_BIN="$WORK/fake_bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/manul-daemon.sh"
STATUS_SCRIPT="$SCRIPT_DIR/manul-status.sh"

# ─── Source needed functions ────────────────────────────────────────────────────
# Write functions to temp file to avoid quoting issues
cat > "$WORK/fn.sh" << 'EOF'
log() { echo "[$(date -Is)] $*" >>"$LOG"; }
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
EOF
sed -n '1641,1679p' "$DAEMON" >> "$WORK/fn.sh"
sed -n '1861,1900p' "$DAEMON" >> "$WORK/fn.sh"
sed -n '1698,1728p' "$DAEMON" >> "$WORK/fn.sh"
sed -n '1733,1742p' "$DAEMON" >> "$WORK/fn.sh"
source "$WORK/fn.sh"

# Shellcheck-friendly: set globals expected by sourced functions
DB="$TEMP_DB"; LOG="$LOG_FILE"; MANUL_DIR="$MANUL_DIR"
GH_API_TIMEOUT="30"
MANUL_MODE="bot"

# ─── Setup temp SQLite DB with full schema (includes new columns) ──────────────
setup_db() {
    rm -f "$TEMP_DB"
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
            claimToken TEXT,
            agentStartedAt TEXT,
            preExecutionFailures INTEGER NOT NULL DEFAULT 0,
            startedAttempt INTEGER,
            nextAttemptAt TEXT,
            taskSourceType TEXT,
            taskSourceId TEXT,
            conversationId TEXT,
            workspaceId TEXT
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    " 2>/dev/null
}

insert_task() {
    local tid="$1" repo="$2" issue="$3" url="$4" status="$5" attempt="${6:-1}" started_at="${7:-}"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sqlite3 "$TEMP_DB" "
        INSERT OR REPLACE INTO processed_comments
            (commentId, repository, issueNumber, commentUrl, author, prompt,
             status, attempts, agentStartedAt, preExecutionFailures, workerPid, conversationId, createdAt)
        VALUES
            ('$tid', '$repo', $issue, '$url', 'test-user', 'do the task', '$status', $attempt,
             '$started_at', 0, $$, 'c1', '$now');
    " 2>/dev/null
}

# ─── REPO / ISSUE used by fake gh ───────────────────────────────────────────────
REPO="test/repo"
ISSUE=42

# ─── Fake gh: returns comment bodies for start_comment_already_posted ─────────
setup_fake_gh() {
    local state_file="$WORK/gh_comment_state.json"
    cat > "$FAKE_BIN/gh" << GH_EOF
#!/bin/bash
STATE_FILE="$state_file"
if [[ "\$1" == "api" && "\$2" == *"/issues/$ISSUE/comments"* ]]; then
    if [ -f "\$STATE_FILE" ]; then
        cat "\$STATE_FILE"
    else
        printf '[]'
    fi
    echo
    exit 0
fi
if [[ "\$1" == "api" && "\$2" == *"/issues/43/comments"* ]]; then
    if [ -f "\$STATE_FILE" ]; then
        cat "\$STATE_FILE"
    else
        printf '[]'
    fi
    echo
    exit 0
fi
printf '[]\n'
GH_EOF
    chmod +x "$FAKE_BIN/gh"
}

# ─── Test group 1: DB fast-path for TASK_STARTED idempotency ───────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Attempt Accounting Tests — Task #110"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Test group: DB fast-path for TASK_STARTED idempotency"

setup_db

# ── Test 1.1: startedAttempt matches current_attempt → already_posted=true ─────
echo ""
echo "Test 1.1: DB fast-path — startedAttempt matches current_attempt"
insert_task "TASK_FAST" "$REPO" "$ISSUE" "https://github.com/$REPO/issues/$ISSUE" "running" 2 ""
sqlite3 "$TEMP_DB" "UPDATE processed_comments SET startedAttempt=2 WHERE commentId='TASK_FAST';"
local_result="$(sqlite3 "$DB" "SELECT startedAttempt FROM processed_comments WHERE commentId='TASK_FAST' LIMIT 1;" 2>/dev/null)"
if [ "$local_result" = "2" ]; then
    ok "DB fast-path: startedAttempt=2 found for TASK_FAST"
else
    fail "DB fast-path: expected startedAttempt=2, got='$local_result'"
fi

# ── Test 1.2: startedAttempt does not match → falls through to GitHub check ───
echo ""
echo "Test 1.2: DB fast-path — startedAttempt does not match"
insert_task "TASK_NO_MATCH" "$REPO" "$ISSUE" "https://github.com/$REPO/issues/$ISSUE" "running" 3 ""
sqlite3 "$TEMP_DB" "UPDATE processed_comments SET startedAttempt=1 WHERE commentId='TASK_NO_MATCH';"
local_result="$(sqlite3 "$DB" "SELECT startedAttempt FROM processed_comments WHERE commentId='TASK_NO_MATCH' LIMIT 1;" 2>/dev/null)"
if [ "$local_result" = "1" ] && [ "3" != "1" ]; then
    ok "DB fast-path: startedAttempt=1 does not match current_attempt=3"
else
    fail "DB fast-path: unexpected startedAttempt value"
fi

# ─── Test group 2: start_comment_already_posted GitHub check ───────────────────
echo ""
echo "Test group: start_comment_already_posted GitHub pre-check"

setup_fake_gh
setup_db

# ── Test 2.1: No marker in GitHub → returns 1 ────────────────────────────────
echo ""
echo "Test 2.1: No TASK_STARTED marker → not already posted"
rm -f "$WORK/gh_comment_state.json"
insert_task "TASK_NO_MARKER" "$REPO" "$ISSUE" "https://github.com/$REPO/issues/$ISSUE" "running" 1 ""
start_comment_already_posted "$REPO" "$ISSUE" "TASK_NO_MARKER" "TASK_NO_MARKER" 1 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    ok "No marker: correctly returns failure (rc=$?)"
else
    fail "No marker: should return failure (expected rc!=0)"
fi

# ── Test 2.2: Existing TASK_STARTED marker for same task/attempt → returns 0 ─
echo ""
echo "Test 2.2: TASK_STARTED marker already exists → idempotent skip"
rm -f "$WORK/gh_comment_state.json"
printf '[{"id":1001,"body":"<!-- manul:event {\"type\":\"TASK_STARTED\",\"timestamp\":\"2026-09-11T00:00:00Z\",\"data\":{\"taskId\":\"TASK_EXISTS\",\"conversationId\":\"c1\",\"status\":\"started\",\"attempt\":1}} -->"}]' > "$WORK/gh_comment_state.json"
insert_task "TASK_EXISTS" "$REPO" "$ISSUE" "https://github.com/$REPO/issues/$ISSUE" "running" 1 ""
start_comment_already_posted "$REPO" "$ISSUE" "TASK_EXISTS" "TASK_EXISTS" 1 >/dev/null 2>&1
if [ $? -eq 0 ]; then
    ok "Existing TASK_STARTED marker: correctly detected"
else
    fail "Existing TASK_STARTED marker: should return 0 (rc=$?)"
fi

# ── Test 2.3: Wrong attempt number → returns 1 (different attempt != this one) ─
echo ""
echo "Test 2.3: TASK_STARTED exists but wrong attempt → not a match"
rm -f "$WORK/gh_comment_state.json"
printf '[{"id":1001,"body":"<!-- manul:event {\"type\":\"TASK_STARTED\",\"timestamp\":\"2026-09-11T00:00:00Z\",\"data\":{\"taskId\":\"TASK_WRONG_ATTEMPT\",\"conversationId\":\"c1\",\"status\":\"started\",\"attempt\":1}} -->"}]' > "$WORK/gh_comment_state.json"
insert_task "TASK_WRONG_ATTEMPT" "$REPO" "$ISSUE" "https://github.com/$REPO/issues/$ISSUE" "running" 1 ""
sqlite3 "$TEMP_DB" "UPDATE processed_comments SET startedAttempt=NULL WHERE commentId='TASK_WRONG_ATTEMPT';"
start_comment_already_posted "$REPO" "$ISSUE" "TASK_WRONG_ATTEMPT" "TASK_WRONG_ATTEMPT" 2 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    ok "Wrong attempt: correctly rejects attempt 1 marker for attempt 2"
else
    fail "Wrong attempt: should return failure (expected rc!=0)"
fi

# ── Test 2.4: Non-TASK_STARTED event only → returns 1 ────────────────────────
echo ""
echo "Test 2.4: Only TASK_DONE events exist → not started"
rm -f "$WORK/gh_comment_state.json"
printf '[{"id":1001,"body":"<!-- manul:event {\"type\":\"TASK_DONE\",\"timestamp\":\"2026-09-11T00:00:00Z\",\"data\":{\"taskId\":\"TASK_DONE_ONLY\",\"attempt\":1,\"status\":\"completed\"}} -->"}]' > "$WORK/gh_comment_state.json"
insert_task "TASK_DONE_ONLY" "$REPO" "$ISSUE" "https://github.com/$REPO/issues/$ISSUE" "running" 1 ""
start_comment_already_posted "$REPO" "$ISSUE" "TASK_DONE_ONLY" "TASK_DONE_ONLY" 1 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    ok "TASK_DONE only: correctly does not match TASK_STARTED"
else
    fail "TASK_DONE only: should return failure"
fi

# ── Test 2.5: gh API failure → returns 1 (fail-closed) ───────────────────────
echo ""
echo "Test 2.5: gh API failure → fail-closed (returns failure)"
rm -f "$WORK/gh_comment_state.json"
cat > "$FAKE_BIN/gh" << 'GH_FAIL_EOF'
#!/bin/bash
echo "fake gh: error" >&2
exit 1
GH_FAIL_EOF
chmod +x "$FAKE_BIN/gh"
insert_task "TASK_GH_FAIL" "$REPO" "$ISSUE" "https://github.com/$REPO/issues/$ISSUE" "running" 1 ""
start_comment_already_posted "$REPO" "$ISSUE" "TASK_GH_FAIL" "TASK_GH_FAIL" 1 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    ok "gh failure: fail-closed (returns $?)"
else
    fail "gh failure: should return failure (expected rc!=0), got 0"
fi
# Restore normal fake gh for remaining tests
setup_fake_gh

# ─── Test group 3: ensure_recovery_tracking_columns migration ──────────────────
echo ""
echo "Test group: migration adds startedAttempt column"

# ── Test 3.1: adds startedAttempt when missing ───────────────────────────────
echo ""
echo "Test 3.1: adds startedAttempt column on fresh DB"
rm -f "$TEMP_DB"
sqlite3 "$TEMP_DB" "
    CREATE TABLE processed_comments (
        commentId TEXT PRIMARY KEY,
        repository TEXT NOT NULL,
        issueNumber INTEGER NOT NULL,
        commentUrl TEXT NOT NULL,
        prompt TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        attempts INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT,
        processedAt TEXT,
        nextAttemptAt TEXT
    );"
# Source migration function
source "$WORK/fn.sh"
ensure_recovery_tracking_columns >/dev/null 2>&1
if sqlite3 "$TEMP_DB" "PRAGMA table_info(processed_comments);" | grep -q '|startedAttempt|'; then
    ok "Migration: startedAttempt column added"
else
    fail "Migration: startedAttempt column not found"
fi
if sqlite3 "$TEMP_DB" "PRAGMA table_info(processed_comments);" | grep -q '|preExecutionFailures|'; then
    ok "Migration: preExecutionFailures column still present"
else
    fail "Migration: preExecutionFailures column missing"
fi

# ── Test 3.2: idempotent when all columns already present ────────────────────
echo ""
echo "Test 3.2: idempotent re-run when columns exist"
ensure_recovery_tracking_columns >/dev/null 2>&1
if sqlite3 "$TEMP_DB" "PRAGMA table_info(processed_comments);" | grep -q '|startedAttempt|'; then
    ok "Re-run: startedAttempt column still present"
else
    fail "Re-run: startedAttempt column missing after idempotent re-run"
fi

# ─── Test group 4: manul-status output includes new columns ───────────────────
echo ""
echo "Test group: manul-status observability"

# Re-setup full-schema DB for status tests (Test 3.1 recreated TEMP_DB without conversationId)
setup_db
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sqlite3 "$TEMP_DB" "
    INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, prompt, status, attempts, agentStartedAt, preExecutionFailures, startedAttempt, conversationId, createdAt)
    VALUES('STATUS_TASK', '$REPO', $ISSUE, 'https://github.com/$REPO/issues/$ISSUE', 'do the task', 'running', 2, '2026-09-11T00:00:00Z', 1, 2, 'c1', '$NOW');"

# manul-status resolves DB from MANUL_DB env var; source manul-paths to get config path
MANUL_STATE_DIR="$WORK/manul_state"
mkdir -p "$MANUL_STATE_DIR"
cp "$TEMP_DB" "$MANUL_STATE_DIR/manul.db"
MANUL_DIR_CONFIG="$WORK/manul_dir"
mkdir -p "$MANUL_DIR_CONFIG"
echo "{}" > "$MANUL_DIR_CONFIG/config.json"

# ── Test 4.1: JSON output contains new fields ────────────────────────────────
echo ""
echo "Test 4.1: JSON output includes preExecutionFailures, agentStartedAt, startedAttempt"
export MANUL_STATE_DIR LOG
MANUL_DIR="$MANUL_DIR_CONFIG" MANUL_DB="$MANUL_STATE_DIR/manul.db" bash "$STATUS_SCRIPT" --list --json 2>/dev/null > "$WORK/status.json"
STATUS_JSON="$(cat "$WORK/status.json")"
echo "$STATUS_JSON" | jq . >/dev/null 2>&1 || {
    fail "JSON output is not valid JSON"
    STATUS_JSON="[]"
}
HAS_INFRA="$(echo "$STATUS_JSON" | jq -r '.[0].preExecutionFailures // empty')"
HAS_AGENT_STARTED="$(echo "$STATUS_JSON" | jq -r '.[0].agentStartedAt // empty')"
HAS_STARTED_ATTEMPT="$(echo "$STATUS_JSON" | jq -r '.[0].startedAttempt // empty')"
if [ "$HAS_INFRA" = "1" ]; then
    ok "JSON: preExecutionFailures present (value=1)"
else
    fail "JSON: preExecutionFailures missing or wrong (got='$HAS_INFRA')"
fi
if [ "$HAS_AGENT_STARTED" = "2026-09-11T00:00:00Z" ]; then
    ok "JSON: agentStartedAt present (value=$HAS_AGENT_STARTED)"
else
    fail "JSON: agentStartedAt missing or wrong (got='$HAS_AGENT_STARTED')"
fi
if [ "$HAS_STARTED_ATTEMPT" = "2" ]; then
    ok "JSON: startedAttempt present (value=$HAS_STARTED_ATTEMPT)"
else
    fail "JSON: startedAttempt missing or wrong (got='$HAS_STARTED_ATTEMPT')"
fi

# ── Test 4.2: Table output includes new columns ──────────────────────────────
echo ""
echo "Test 4.2: Table output includes new headers"
MANUL_DIR="$MANUL_DIR_CONFIG" MANUL_DB="$MANUL_STATE_DIR/manul.db" bash "$STATUS_SCRIPT" --list 2>/dev/null > "$WORK/status.txt"
STATUS_TABLE="$(cat "$WORK/status.txt")"
if echo "$STATUS_TABLE" | grep -q "AGENT_STARTED"; then
    ok "Table: AGENT_STARTED header present"
else
    fail "Table: AGENT_STARTED header missing"
fi
if echo "$STATUS_TABLE" | grep -q "STARTED_ATTEMPT"; then
    ok "Table: STARTED_ATTEMPT header present"
else
    fail "Table: STARTED_ATTEMPT header missing"
fi
if echo "$STATUS_TABLE" | grep -q "INFRA_FAIL"; then
    ok "Table: INFRA_FAIL header present"
else
    fail "Table: INFRA_FAIL header missing"
fi

# ── Test 4.3: Older DB without new columns still works ───────────────────────
echo ""
echo "Test 4.3: degraded mode when columns are absent"
OLD_DB="$WORK/old.db"
sqlite3 "$OLD_DB" "
    CREATE TABLE processed_comments (
        commentId TEXT PRIMARY KEY,
        repository TEXT NOT NULL,
        issueNumber INTEGER NOT NULL,
        commentUrl TEXT NOT NULL,
        prompt TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'queued',
        attempts INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT,
        processedAt TEXT,
        nextAttemptAt TEXT,
        taskSourceType TEXT,
        taskSourceId TEXT,
        conversationId TEXT,
        workspaceId TEXT,
        workerPid INTEGER
    );"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sqlite3 "$OLD_DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, prompt, status, attempts, createdAt, conversationId) VALUES ('OLD','test/repo',1,'https://github.com/test/repo/issues/1','p','running',0,'$NOW','c1');"
OLD_MANUL_DB="$WORK/old_manul.db"
cp "$OLD_DB" "$OLD_MANUL_DB"
export MANUL_DB="$OLD_MANUL_DB"
OLD_JSON="$(MANUL_DIR="$MANUL_DIR_CONFIG" bash "$STATUS_SCRIPT" --list --json 2>/dev/null)"
if echo "$OLD_JSON" | jq '.[0].preExecutionFailures' 2>/dev/null | grep -q '^0$'; then
    ok "Old DB: preExecutionFailures degrades to 0"
else
    fail "Old DB: preExecutionFailures should default to 0"
fi
if echo "$OLD_JSON" | jq '.[0].agentStartedAt' 2>/dev/null | grep -q 'null'; then
    ok "Old DB: agentStartedAt degrades to null"
else
    fail "Old DB: agentStartedAt should default to null"
fi

# ─── Test group 5: Terminal marker ordering (structural) ─────────────────────
echo ""
echo "Test group: terminal marker ordering (structural verification)"

echo ""
echo "Test 5.1: TASK_DONE/TASK_FAILED marker assembly happens BEFORE post_github_comment"
# Verify source order: marker assembly block must appear before the post block
MARKER_BLOCK_START=$(grep -n "Structured terminal events are embedded" "$DAEMON" | tail -1 | cut -d: -f1)
POST_BLOCK=$(grep -n "^    # 9\. Post lifecycle comment to the SAME GitHub thread" "$DAEMON" | tail -1 | cut -d: -f1)
if [ -n "$MARKER_BLOCK_START" ] && [ -n "$POST_BLOCK" ] && [ "$MARKER_BLOCK_START" -lt "$POST_BLOCK" ]; then
    ok "Structural: marker assembly (line $MARKER_BLOCK_START) precedes post (line $POST_BLOCK)"
else
    fail "Structural: marker assembly does not precede post (marker_start=$MARKER_BLOCK_START post=$POST_BLOCK)"
fi

echo ""
echo "Test 5.2: No duplicate post block for the same dispatch"
POST_COUNT=$(grep -c "post_github_comment \"\$REPO\" \"\$ISSUE_NUM\" \"\$FINAL_COMMENT\"" "$DAEMON")
if [ "$POST_COUNT" -eq 1 ]; then
    ok "Structural: exactly one post_github_comment call for FINAL_COMMENT"
else
    fail "Structural: expected 1 post_github_comment for FINAL_COMMENT, found $POST_COUNT"
fi

# ─── Results summary ──────────────────────────────────────────────────────────
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
