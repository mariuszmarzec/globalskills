#!/bin/bash
set -uo pipefail

# Simplified test for verify_result_comment bug fix
# Tests the core fix: .user.login vs .author.login

MANUL_DIR="/home/marzec/.openclaw/manul"
DAEMON="/home/marzec/.globalskills/skills/manul-github-bot/manul-daemon.sh"
DB="$MANUL_DIR/manul.db"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Source required functions
eval "$(sed -n '/^verify_result_comment/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^log/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^lc_log/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^sql_escape/,/^}/p' "$DAEMON")"

# Setup fake gh
cat > "$TEMP_DIR/gh" << 'GH_EOF'
#!/bin/bash
REPO=""
ISSUE=""
JQ_FILTER=""
while [[ $# -gt 0 ]]; do
    case $1 in
        api) shift; if [[ "$1" =~ repos/([^/]+)/([^/]+)/issues/([^/]+)/comments ]]; then REPO="${BASH_REMATCH[1]}__${BASH_REMATCH[2]}"; ISSUE="${BASH_REMATCH[3]}"; fi; shift ;;
        --jq) shift; JQ_FILTER="$1"; shift ;;
        *) shift ;;
    esac
done
RESPONSE_FILE="$TEMP_DIR/responses/${REPO}_${ISSUE}.json"
if [[ -f "$RESPONSE_FILE" ]]; then
    jq "$JQ_FILTER" < "$RESPONSE_FILE" 2>/dev/null || echo ""
fi
GH_EOF
chmod +x "$TEMP_DIR/gh"
mkdir -p "$TEMP_DIR/responses"
export PATH="$TEMP_DIR:$PATH"

# Setup DB
setup_db() {
    local comment_id="$1"
    local repo="$2"
    local issue="$3"
    local attempt="$4"
    local comment_url="https://github.com/${repo}/issues/${issue}#issuecomment-${comment_id}"
    sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments (commentId, repository, issueNumber, status, commentUrl, attempts, workerPid) VALUES ('$comment_id', '$repo', '$issue', 'queued', '$comment_url', $attempt, 0);" 2>/dev/null
}

# Test function
test_fix() {
    local test_name="$1"
    local repo="$2"
    local issue="$3"
    local comment_id="$4"
    local attempt="$5"
    local response_json="$6"
    local expected_rc="$7"
    
    echo -n "Test: $test_name ... "
    
    # Create response file
    printf '%s\n' "$response_json" > "$TEMP_DIR/responses/${repo//\//__}_${issue}.json"
    
    # Setup DB
    setup_db "$comment_id" "$repo" "$issue" "$attempt"
    
    # Run verification
    verify_result_comment "$repo" "$issue" "$comment_id" "$comment_id" "$attempt" 2>/dev/null
    local rc=$?
    
    if [[ "$rc" -eq "$expected_rc" ]]; then
        echo -e "${GREEN}PASS${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC} (expected $expected_rc, got $rc)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "=========================================="
echo "Testing verify_result_comment bug fix"
echo "=========================================="
echo ""

# Core tests
test_fix "Fixed: .user.login matches Manul-Bot" \
    "owner/repo" "1" "1" "1" \
    '[{"id": 1, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:1:attempt:1 -->\\nResult"}]' \
    0

test_fix "Bug: .author.login does NOT match (old behavior)" \
    "owner/repo" "1" "2" "1" \
    '[{"id": 2, "author": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:2:attempt:1 -->\\nResult"}]' \
    1

test_fix "Reply comment with .user.login" \
    "owner/repo" "1" "3" "1" \
    '[{"id": 3, "user": {"login": "Manul-Bot"}, "in_reply_to_id": 100, "body": "<!-- manul-task:3:attempt:1 -->\\nReply"}]' \
    0

test_fix "Non-Manul author filtered" \
    "owner/repo" "1" "4" "1" \
    '[{"id": 4, "user": {"login": "human-user"}, "in_reply_to_id": null, "body": "<!-- manul-task:4:attempt:1 -->\\nResult"}]' \
    1

test_fix "Lifecycle comment rejected" \
    "owner/repo" "1" "5" "1" \
    '[{"id": 5, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "✅ Manul completed"}]' \
    1

test_fix "Multiple matches rejected" \
    "owner/repo" "1" "6" "1" \
    '[{"id": 6a, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:6:attempt:1 -->\\nFirst"}, {"id": 6b, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:6:attempt:1 -->\\nSecond"}]' \
    1

test_fix "Wrong attempt number rejected" \
    "owner/repo" "1" "7" "1" \
    '[{"id": 7, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:7:attempt:2 -->\\nWrong"}]' \
    1

echo ""
echo "=========================================="
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
echo "=========================================="

exit $TESTS_FAILED
