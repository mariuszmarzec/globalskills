#!/usr/bin/env bash
# Regression tests for manul-comments-remove.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPROOT="$(mktemp -d /tmp/manul-comments-remove-test-XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT
FAKE_BIN="$TMPROOT/bin"
LOG="$TMPROOT/curl.log"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -e
case "$*" in
  "auth token")
    echo token
    ;;
  *"pr view"*"--json number"*)
    echo '{"number":34}'
    ;;
  *"pr view"*"--json body"*)
    echo '{"body":""}'
    ;;
  *"api --paginate repos/test-owner/test-repo/pulls/34/comments?per_page=100"*)
    cat "$TEST_COMMENTS_JSON"
    ;;
  *"api --paginate repos/test-owner/test-repo/issues/34/comments"*)
    echo '[]'
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 2
    ;;
esac
GH
chmod +x "$FAKE_BIN/gh"

cat > "$FAKE_BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -e
printf "%s\n" "$*" >> "$CURL_LOG"
printf "204"
CURL
chmod +x "$FAKE_BIN/curl"

cat > "$TMPROOT/comments.json" <<'JSON'
[
  {"id":100,"body":"Original reviewer comment","in_reply_to_id":null},
  {"id":101,"body":"Manul reply 1\n\n— manul 🐈","in_reply_to_id":100},
  {"id":102,"body":"Manul reply 2\n\n— manul 🐈","in_reply_to_id":101},
  {"id":200,"body":"Another Manul thread\n\n— manul 🐈","in_reply_to_id":null}
]
JSON

TEST_COMMENTS_JSON="$TMPROOT/comments.json"
CURL_LOG="$LOG"
export TEST_COMMENTS_JSON CURL_LOG

echo "Test 1: accepts #discussion_r URL and removes only target thread"
> "$LOG"
PATH="$FAKE_BIN:$PATH" "$SCRIPT_DIR/manul-comments-remove.sh" \
  "https://github.com/test-owner/test-repo/pull/34#discussion_r101" > "$TMPROOT/out1"

grep -q "Target: test-owner/test-repo# 34" "$TMPROOT/out1"
grep -q "Deleted:  2" "$TMPROOT/out1"
grep -q "PR review comments: 2" "$TMPROOT/out1"
grep -q "/repos/test-owner/test-repo/pulls/comments/101" "$LOG"
grep -q "/repos/test-owner/test-repo/pulls/comments/102" "$LOG"
if grep -q "/repos/test-owner/test-repo/pulls/comments/200" "$LOG"; then
  echo "FAIL: selective cleanup touched unrelated thread"
  exit 1
fi
echo "PASS"

echo "Test 2: plain PR URL still removes all Manul review-thread comments"
> "$LOG"
PATH="$FAKE_BIN:$PATH" "$SCRIPT_DIR/manul-comments-remove.sh" \
  "https://github.com/test-owner/test-repo/pull/34" > "$TMPROOT/out2"
grep -q "Deleted:  3" "$TMPROOT/out2"
grep -q "/repos/test-owner/test-repo/pulls/comments/101" "$LOG"
grep -q "/repos/test-owner/test-repo/pulls/comments/102" "$LOG"
grep -q "/repos/test-owner/test-repo/pulls/comments/200" "$LOG"
echo "PASS"

echo "=== Results: 2 passed, 0 failed ==="
