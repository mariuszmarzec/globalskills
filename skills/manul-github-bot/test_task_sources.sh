#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TMPROOT="$(mktemp -d /tmp/manul-task-sources-XXXXXX)"
BIN="$TMPROOT/bin"; WORK="$TMPROOT/work"; mkdir -p "$BIN" "$WORK"; trap 'rm -rf "$TMPROOT"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "PASS: $1"; }; fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_contains(){ [[ "$2" == *"$3"* ]] && ok "$1" || fail "$1"; }
assert_not_contains(){ [[ "$2" != *"$3"* ]] && ok "$1" || fail "$1"; }
source "$SCRIPT_DIR/task-source.sh"
cat >"$WORK/config.json" <<'JSON'
{"repositories":["legacy/repo"],"taskSources":[{"type":"github_issues","enabled":true,"repositories":["owner/issues"]},{"type":"todo_api","enabled":false,"baseUrl":"http://todo.local"}]}
JSON
sources="$(task_source_configured_sources "$WORK/config.json")"
assert_contains "enabled GitHub source appears" "$sources" ""type":"github_issues""
assert_not_contains "disabled Todo source is omitted" "$sources" ""type":"todo_api""
cat >"$WORK/legacy.json" <<'JSON'
{"repositories":["owner/legacy"]}
JSON
legacy="$(task_source_configured_sources "$WORK/legacy.json")"
assert_contains "legacy config maps to GitHub Issues" "$legacy" ""type":"github_issues""
assert_contains "legacy repository preserved" "$legacy" "owner/legacy"
cat >"$WORK/todo.json" <<'JSON'
{"type":"todo_api","enabled":true,"baseUrl":"http://todo.local","tokenEnv":"MANUL_TODO_PAT","trigger":"/manul"}
JSON
cat >"$BIN/curl" <<'CURL'
#!/usr/bin/env bash
cat <<'JSON'
[{"id":7,"ownerId":1,"description":"/manul Fix sync","addedTime":"2026-10-08T10:00:00Z","modifiedTime":"2026-10-08T11:00:00Z","isToDo":true},{"id":8,"ownerId":1,"description":"Do not run","isToDo":true}]
JSON
CURL
chmod +x "$BIN/curl"
PATH="$BIN:$PATH" MANUL_TODO_PAT="secret" todo="$(PATH="$BIN:$PATH" MANUL_TODO_PAT="secret" bash -c "source \"$SCRIPT_DIR/task-source-todo-api.sh\"; task_source_todo_api_poll \"$(cat "$WORK/todo.json")\"")"
assert_contains "Todo trigger is discovered" "$todo" ""taskSourceType":"todo_api""
assert_contains "Todo id preserved" "$todo" ""taskSourceId":"7""
assert_not_contains "Todo item without trigger ignored" "$todo" ""taskSourceId":"8""
assert_not_contains "PAT never appears in normalized data" "$todo" "secret"
if task_source_type_is_supported github_pr; then fail "PR must not be a task source"; else ok "PR is not a supported task source"; fi
echo "Results: $PASS passed, $FAIL failed"; exit "$FAIL"
