#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "ERROR: $*" >&2; exit 1; }

test_helpers_and_persistence() {
  local dir db
  dir="$(mktemp -d /tmp/manul-conv-reg-XXXXXX)"
  db="$dir/manul.db"
  sqlite3 "$db" "CREATE TABLE conversation_messages(messageId TEXT PRIMARY KEY, conversationId TEXT, commentId TEXT, repo TEXT, issueNumber INTEGER, author TEXT, body TEXT, commentUrl TEXT, createdAt TEXT, messageType TEXT);"

  source <(sed -n '/^get_review_thread_root_id()/,/^}/p' "$SCRIPT_DIR/poll.sh")
  source <(sed -n '/^persist_conversation_message()/,/^}/p' "$SCRIPT_DIR/poll.sh")
  source <(sed -n '/^build_conversation_context()/,/^}/p' "$SCRIPT_DIR/poll.sh")
  uuidgen() { echo "u-$RANDOM"; }
  DB="$db" LOG="$dir/test.log"

  local comments root reply_root second_root
  comments='[{"id":101,"in_reply_to_id":null},{"id":102,"in_reply_to_id":101},{"id":103,"in_reply_to_id":102},{"id":201,"in_reply_to_id":null}]'
  root="$(get_review_thread_root_id "$comments" 103)"
  reply_root="$(get_review_thread_root_id "$comments" 102)"
  second_root="$(get_review_thread_root_id "$comments" 201)"
  [ "$root" = 101 ] || fail "reply 103 resolved to root $root"
  [ "$reply_root" = 101 ] || fail "reply 102 resolved to root $reply_root"
  [ "$second_root" = 201 ] || fail "second thread resolved to root $second_root"

  persist_conversation_message 'conv-test-org/test-repo-issue-1' test-org/test-repo 1 100 user 'Add a test for multiply(2, 3) == 6' 'https://example/100' '2026-01-01T00:00:01Z' issue-comment
  persist_conversation_message 'conv-test-org/test-repo-issue-1' test-org/test-repo 1 101 user 'Also make sure the assertion uses float comparison.' 'https://example/101' '2026-01-01T00:00:02Z' comment
  persist_conversation_message 'conv-test-org/test-repo-issue-1' test-org/test-repo 1 102 user 'Now implement the change according to my previous feedback.' 'https://example/102' '2026-01-01T00:00:03Z' issue-comment

  local count context
  count="$(sqlite3 "$db" "SELECT COUNT(*) FROM conversation_messages WHERE conversationId='conv-test-org/test-repo-issue-1';")"
  [ "$count" -eq 3 ] || fail "expected 3 messages, got $count"
  context="$(build_conversation_context 'conv-test-org/test-repo-issue-1')"
  grep -Fq 'Also make sure the assertion uses float comparison.' <<<"$context" || fail 'ordinary feedback missing from follow-up context'

  persist_conversation_message 'conv-test-org/test-repo-issue-1' test-org/test-repo 1 101 user 'Also make sure the assertion uses float comparison.' 'https://example/101' '2026-01-01T00:00:02Z' comment
  count="$(sqlite3 "$db" "SELECT COUNT(*) FROM conversation_messages WHERE conversationId='conv-test-org/test-repo-issue-1';")"
  [ "$count" -eq 3 ] || fail "duplicate persistence created $count rows"
  rm -rf "$dir"
}

bash -n "$SCRIPT_DIR/poll.sh"
test_helpers_and_persistence
echo 'PASS: conversation regressions (1/1)'
