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
    printf '%s\n' '[
      {"id":4098362711,"body":"/manul original user request","in_reply_to_id":null},
      {"id":4126334268,"body":"/manul do this","in_reply_to_id":4098362711},
      {"id":4126396380,"body":"working\n\n— manul 🐈","in_reply_to_id":4126334268},
      {"id":4164153672,"body":"result\n\n— manul 🐈","in_reply_to_id":4126396380},
      {"id":500,"body":"unrelated Manul thread\n\n— manul 🐈","in_reply_to_id":null}
    ]'
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
out_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -z "$out_file" ] || : > "$out_file"
printf "204"
CURL
chmod +x "$FAKE_BIN/curl"

echo "Test 1: accepts #discussion_r URL and removes only target thread"
> "$LOG"
PATH="$FAKE_BIN:$PATH" "$SCRIPT_DIR/manul-comments-remove.sh" \
  "https://github.com/test-owner/test-repo/pull/34#discussion_r4126334268" > "$TMPROOT/out1"

cat "$TMPROOT/out1"
grep -q "Target: test-owner/test-repo# 34" "$TMPROOT/out1"
grep -q "Review thread filter: #discussion_r4126334268" "$TMPROOT/out1"
grep -q "Deleted:  2" "$TMPROOT/out1"
grep -q "PR review comments: 2" "$TMPROOT/out1"
grep -q "pulls/comments/4126334268" "$LOG"
grep -q "pulls/comments/4126396380" "$LOG"
if grep -q "pulls/comments/500" "$LOG"; then
  echo "FAIL: selective cleanup touched unrelated thread"
  exit 1
fi
echo "PASS"

echo "Test 2: plain PR URL still removes all Manul review comments"
> "$LOG"
PATH="$FAKE_BIN:$PATH" "$SCRIPT_DIR/manul-comments-remove.sh" \
  "https://github.com/test-owner/test-repo/pull/34" > "$TMPROOT/out2"
cat "$TMPROOT/out2"
grep -q "Deleted:  3" "$TMPROOT/out2"
grep -q "pulls/comments/4126334268" "$LOG"
grep -q "pulls/comments/4126396380" "$LOG"
grep -q "pulls/comments/500" "$LOG"
echo "PASS"

echo "=== Results: 2 passed, 0 failed ==="
