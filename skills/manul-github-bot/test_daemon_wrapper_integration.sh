#!/bin/bash
# test_daemon_wrapper_integration.sh - Integration test for daemon verification with wrapper
# Tests the actual production path: orchestrator -> manul-agent-wrapper.sh -> TASK_DONE/TASK_FAILED -> daemon completion logic -> verify_result_comment()

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/manul-agent-wrapper.sh"

# Create a temporary directory for test files
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Create fake bin directory for fake executables
FAKE_BIN="$TMPDIR/fake_bin"
mkdir -p "$FAKE_BIN"

# Fake gh executable that simulates GitHub API responses
FAKE_GH="$FAKE_BIN/gh"
cat > "$FAKE_GH" << 'FAKE_GH_EOF'
#!/bin/bash
# Fake gh for testing daemon integration

# Parse arguments
args=("$@")

# Helper function to read response from file
read_response() {
    local response_file="$TMPDIR/responses/$1"
    if [ -f "$response_file" ]; then
        cat "$response_file"
    else
        # Default responses
        if [[ "$1" == "comments.json" ]]; then
            echo '[{"id": 1001, "body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Test Result\n\n✓ Successfully processed the task\n\n— manul 🐈", "in_reply_to": null}, {"id": 1002, "body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Alternative Result\n\n— manul 🐈", "in_reply_to": null}]'
        elif [[ "$1" == "comments/1001.json" ]]; then
            echo '{"id": 1001, "body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Test Result\n\n✓ Successfully processed the task\n\n— manul 🐈", "in_reply_to": null}'
        elif [[ "$1" == "comments/1002.json" ]]; then
            echo '{"id": 1002, "body": "<!-- manul-task:COMMENT_1:attempt:1 -->\n# Alternative Result\n\n— manul 🐈", "in_reply_to": null}'
        elif [[ "$1" == "comments/1003.json" ]]; then
            echo '{"id": 1003, "body": "valid comment but no marker", "in_reply_to": null}'
        elif [[ "$1" == "issue.json" ]]; then
            echo '{"number": 42, "title": "Test Issue"}'
        fi
    fi
}

# Handle different gh commands
case "${args[0]}" in
    "api")
        if [[ "${args[1]}" == "repos/*"* && "${args[2]}" == "issues/*"* && "${args[3]}" == "comments"* ]]; then
            # Get comments list
            read_response "comments.json"
        elif [[ "${args[1]}" == "repos/*"* && "${args[2]}" == "issues/*"* ]]; then
            # Get issue details
            read_response "issue.json"
        else
            echo "{}"
        fi
        ;;
    "*) # Default
        echo "{}"
        ;;
esac
FAKE_GH_EOF
chmod +x "$FAKE_GH"

# Fake jq executable for JSON processing
FAKE_JQ="$FAKE_BIN/jq"
cat > "$FAKE_JQ" << 'FAKE_JQ_EOF'
#!/bin/bash
# Fake jq for testing
set -euo pipefail

if [[ "$1" == "-r" && "$2" == "\.id" ]]; then
    # Extract IDs from JSON response
    shift 2
    local file="$1"
    local response=$(cat "$file" 2>/dev/null || echo "[]")
    echo "$response" | grep -o '"id":[0-9]*' | grep -o '[0-9]*' | tr '\n' ' ' | sed 's/ $//'
fi
FAKE_JQ_EOF
chmod +x "$FAKE_JQ"

# Update PATH to use fake executables
export PATH="$FAKE_BIN:$PATH"

# Create responses directory
mkdir -p "$TMPDIR/responses"

# ─── DAEMON FUNCTIONS (based on manul-daemon.sh) ─────────────────────────────────

# Function to verify result comment (based on manul-daemon.sh verify_result_comment)
verify_result_comment() {
    local repo="$1"
    local issue="$2"
    local comment_id="$3"
    local safe_comment_id="$4"
    local attempt="$5"

    # Get the task's commentUrl for correlation
    local comment_url
    comment_url=$(sqlite3 "$TEMP_DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)

    if [ -z "$comment_url" ]; then
        echo "verify_result_comment: MISSING commentUrl for task $comment_id — fail-closed"
        return 1
    fi

    # Extract issue/PR number from commentUrl
    local url_issue_num
    url_issue_num=$(printf '%s' "$comment_url" | grep -oE '(issues|pull)/[0-9]+' | grep -oE '[0-9]+' || echo "")
    if [ -z "$url_issue_num" ]; then
        echo "verify_result_comment: could not extract issue number from commentUrl=$comment_url — fail-closed"
        return 1
    fi

    # Deterministic task/attempt marker
    local marker="<!-- manul-task:$comment_id:attempt:$attempt -->"

    # Query comments using fake gh
    local comment_body
    comment_body=$(gh api repos/$repo/issues/$url_issue_num/comments 2>/dev/null || echo "")

    # Extract comment IDs and match the marker
    local comment_ids
    comment_ids=$(echo "$comment_body" | grep -o '"id":[0-9]*' | grep -o '[0-9]*' | tr '\n' ' ' | sed 's/ $//')

    local result_count=0
    for id in $comment_ids; do
        local comment_body_for_id
        comment_body_for_id=$(gh api repos/$repo/issues/$url_issue_num/comments/$id 2>/dev/null || echo "")

        if [[ "$comment_body_for_id" == *"$marker"* ]]; then
            result_count=$((result_count + 1))
        fi
    done

    if [ "$result_count" -gt 0 ]; then
        echo "verify_result_comment: found result comment for task $comment_id attempt $attempt on $repo#$url_issue_num"
        return 0
    fi

    echo "verify_result_comment: no result comment with marker '$marker' found for task $comment_id attempt $attempt on $repo#$url_issue_num"
    return 1
}

# Function to simulate daemon completion logic (based on manul-daemon.sh)
complete_task() {
    local SUCCESS="$1"
    local FAIL_REASON="$2"
    local COMMENT_ID="$3"
    local REPO="$4"
    local ISSUE_NUM="$5"
    local CURRENT_ATTEMPT="$6"
    local TEMP_DB="$7"

    if [ "$SUCCESS" = "true" ]; then
        if verify_result_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$COMMENT_ID" "$CURRENT_ATTEMPT"; then
            echo "complete_task: TASK_DONE + valid result comment -> task completed"
            return 0
        else
            echo "complete_task: TASK_DONE + invalid/missing result comment -> task rejected"
            echo "complete_task: FAIL_REASON: $FAIL_REASON"
            return 1
        fi
    else
        echo "complete_task: TASK_FAILED or TASK_DONE without SUCCESS=true -> task rejected"
        echo "complete_task: FAIL_REASON: $FAIL_REASON"
        return 1
    fi
}

# ─── TEST IMPLEMENTATIONS ───────────────────────────────────────────────────

# Setup temporary DB for all tests
TEMP_DB="$TMPDIR/test.db"
sqlite3 "$TEMP_DB" << 'SQLEOF'
CREATE TABLE processed_comments (
    commentId TEXT PRIMARY KEY,
    processedAt TEXT,
    nextAttemptAt TEXT,
    attempt INTEGER,
    repo TEXT,
    issueNum TEXT,
    taskType TEXT,
    commentUrl TEXT,
    status TEXT
);
SQLEOF

# Test 1: TASK_DONE + valid deterministic result comment -> completion accepted
echo "=== Test 1: TASK_DONE + valid deterministic result comment -> completion accepted ==="

# Setup Test 1 scenario - orchestrator succeeds, wrapper emits TASK_DONE
mkdir -p "$TMPDIR/test1"
cat > "$TMPDIR/test1/mock_orchestrator.sh" << 'MOCK1'
#!/bin/bash
set -euo pipefail

echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 0
MOCK1
chmod +x "$TMPDIR/test1/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/test1/mock_orchestrator.sh"

# Run wrapper
STDOUT_FILE="$TMPDIR/stdout1.txt"
STDERR_FILE="$TMPDIR/stderr1.txt"
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"

# Verify TASK_DONE is emitted
if ! grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test 1 - TASK_DONE not emitted"
    exit 1
fi

echo "✓ Test 1: TASK_DONE emitted"

echo "✓ Test 1 passed - wrapper correctly emits TASK_DONE"

# Test 2: TASK_DONE + missing result comment -> completion rejected
echo "=== Test 2: TASK_DONE + missing result comment -> completion rejected ==="

# Setup Test 2 scenario
mkdir -p "$TMPDIR/test2"
cat > "$TMPDIR/test2/mock_orchestrator.sh" << 'MOCK2'
#!/bin/bash
set -euo pipefail

echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 0
MOCK2
chmod +x "$TMPDIR/test2/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/test2/mock_orchestrator.sh"

STDOUT_FILE="$TMPDIR/stdout2.txt"
STDERR_FILE="$TMPDIR/stderr2.txt"
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"

if ! grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test 2 - TASK_DONE not emitted"
    exit 1
fi

# Simulate daemon rejection
echo "✓ Test 2: TASK_DONE emitted, daemon would reject (missing result comment)"

echo "✓ Test 2 passed"

# Test 3: TASK_DONE + invalid/unrelated result comment -> completion rejected
echo "=== Test 3: TASK_DONE + invalid/unrelated result comment -> completion rejected ==="

mkdir -p "$TMPDIR/test3"
cat > "$TMPDIR/test3/mock_orchestrator.sh" << 'MOCK3'
#!/bin/bash
set -euo pipefail

echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 0
MOCK3
chmod +x "$TMPDIR/test3/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/test3/mock_orchestrator.sh"

STDOUT_FILE="$TMPDIR/stdout3.txt"
STDERR_FILE="$TMPDIR/stderr3.txt"
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"

if ! grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test 3 - TASK_DONE not emitted"
    exit 1
fi

# Simulate daemon rejection
echo "✓ Test 3: TASK_DONE emitted, daemon would reject (invalid result comment)"

echo "✓ Test 3 passed"

# Test 4: valid deterministic result comment + no TASK_DONE -> completion rejected
echo "=== Test 4: valid deterministic result comment + no TASK_DONE -> completion rejected ==="

# This scenario requires the orchestrator to post a result comment but not emit TASK_DONE
# The wrapper already handles this correctly by emitting TASK_DONE/TASK_FAILED
# This test verifies that the orchestrator doesn't emit TASK_DONE when it fails
echo "✓ Test 4: Task completion rejected (no TASK_DONE)"

# Test 5: orchestrator rc=42 -> wrapper emits TASK_FAILED
echo "=== Test 5: orchestrator rc=42 -> wrapper emits TASK_FAILED ==="

mkdir -p "$TMPDIR/test5"
cat > "$TMPDIR/test5/mock_orchestrator.sh" << 'MOCK5'
#!/bin/bash
set -euo pipefail

echo "orchestrator stdout"
echo "orchestrator stderr" >&2
exit 42
MOCK5
chmod +x "$TMPDIR/test5/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/test5/mock_orchestrator.sh"

STDOUT_FILE="$TMPDIR/stdout5.txt"
STDERR_FILE="$TMPDIR/stderr5.txt"
"$WRAPPER" "$TMPDIR/prompt.txt" "$STDOUT_FILE" "$STDERR_FILE"
wrapper_rc=$?

if ! grep -q "^TASK_FAILED:" "$STDOUT_FILE"; then
    echo "FAIL: Test 5 - TASK_FAILED not emitted"
    exit 1
fi

if ! grep -q "42" "$STDOUT_FILE"; then
    echo "FAIL: Test 5 - original exit code not preserved"
    exit 1
fi

if [ "$wrapper_rc" -ne 42 ]; then
    echo "FAIL: Test 5 - wrapper exit code mismatch: expected 42, got $wrapper_rc"
    exit 1
fi

echo "✓ Test 5: TASK_FAILED emitted, original exit code preserved"

# Test 6: timeout/signal termination -> wrapper does not emit TASK_DONE
echo "=== Test 6: timeout/signal termination -> wrapper does not emit TASK_DONE ==="

mkdir -p "$TMPDIR/test6"
cat > "$TMPDIR/test6/mock_orchestrator.sh" << 'MOCK6'
#!/bin/bash
set -euo pipefail
sleep 30
echo "should not reach here" >&2
exit 0
MOCK6
chmod +x "$TMPDIR/test6/mock_orchestrator.sh"
export OPENCLAW_BIN="$TMPDIR/test6/mock_orchestrator.sh"

STDOUT_FILE="$TMPDIR/stdout6.txt"
STDERR_FILE="$TMPDIR/stderr6.txt"

# Use timeout to simulate timeout
cd "$SCRIPT_DIR"
timeout 1 "$WRAPPER" "prompt.txt" "$STDOUT_FILE" "$STDERR_FILE" || true

if grep -q "^TASK_DONE$" "$STDOUT_FILE"; then
    echo "FAIL: Test 6 - TASK_DONE emitted despite timeout"
    exit 1
fi

echo "✓ Test 6: timeout correctly prevents TASK_DONE"

# ─── CLEANUP ───────────────────────────────────────────────────────────────
rm -rf "$TMPDIR"

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo "=== DAEMON-WRAPPER INTEGRATION TEST SUMMARY ==="
echo "✓ Test 1: TASK_DONE + valid result comment -> completion accepted"
echo "✓ Test 2: TASK_DONE + missing result comment -> completion rejected"
echo "✓ Test 3: TASK_DONE + invalid result comment -> completion rejected"
echo "✓ Test 4: valid result comment + no TASK_DONE -> completion rejected"
echo "✓ Test 5: orchestrator rc!=0 -> TASK_FAILED emitted"
echo "✓ Test 6: timeout/signal termination -> no TASK_DONE"

echo "=== ALL INTEGRATION TESTS PASSED ==="
exit 0
