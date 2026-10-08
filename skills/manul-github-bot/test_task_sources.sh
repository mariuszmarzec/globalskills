#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TMPROOT="$(mktemp -d /tmp/manul-task-sources-XXXXXX)"
BIN="$TMPROOT/bin"
WORK="$TMPROOT/work"
mkdir -p "$BIN" "$WORK"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0
FAIL=0
ok(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_contains(){ [[ "$2" == *"$3"* ]] && ok "$1" || fail "$1"; }
assert_not_contains(){ [[ "$2" != *"$3"* ]] && ok "$1" || fail "$1"; }
assert_eq(){ [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (expected $2, got $3)"; }
source "$SCRIPT_DIR/task-source.sh"

cat >"$WORK/config.json" <<'JSON'
{"repositories":["legacy/repo"],"taskSources":[{"type":"github_issues","enabled":true,"repositories":["owner/issues"]},{"type":"todo_api","enabled":false,"baseUrl":"http://todo.local"}]}
JSON
sources="$(task_source_configured_sources "$WORK/config.json")"
assert_contains "enabled GitHub source appears" "$sources" '"type":"github_issues"'
assert_not_contains "disabled Todo source is omitted" "$sources" '"type":"todo_api"'

cat >"$WORK/legacy.json" <<'JSON'
{"repositories":["owner/legacy"]}
JSON
legacy="$(task_source_configured_sources "$WORK/legacy.json")"
assert_contains "legacy config maps to GitHub Issues" "$legacy" '"type":"github_issues"'
assert_contains "legacy repository preserved" "$legacy" "owner/legacy"

cat >"$WORK/multi.json" <<'JSON'
{"taskSources":[{"type":"github_issues","enabled":true,"repositories":["owner/b"]},{"type":"github_issues","enabled":true,"repositories":["owner/a","owner/b"]},{"type":"todo_api","enabled":true,"baseUrl":"http://todo.local"}]}
JSON
multi="$(task_source_configured_sources "$WORK/multi.json")"
count="$(printf "%s\n" "$multi" | wc -l | tr -d " ")"
assert_eq "multiple source entries are preserved" "3" "$count"
assert_contains "first GitHub repository preserved" "$multi" "owner/b"
assert_contains "second GitHub repository preserved" "$multi" "owner/a"
assert_contains "Todo source is preserved when enabled" "$multi" '"type":"todo_api"'

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
export PATH="$BIN:$PATH"
export MANUL_TODO_PAT="secret"
source "$SCRIPT_DIR/task-source-todo-api.sh"
todo_source="$(cat "$WORK/todo.json")"
todo_json="$(task_source_todo_api_poll "$todo_source")"
assert_contains "Todo trigger is discovered" "$todo_json" '"taskSourceType":"todo_api"'
assert_contains "Todo id preserved" "$todo_json" '"taskSourceId":"7"'
assert_not_contains "Todo item without trigger ignored" "$todo_json" '"taskSourceId":"8"'
assert_contains "Todo execution target is explicit" "$todo_json" '"kind":"non_repository"'
assert_not_contains "PAT never appears in normalized data" "$todo_json" "secret"
if task_source_type_is_supported github_pr; then fail "PR must not be a task source"; else ok "PR is not a supported task source"; fi
assert_eq "stable task-source identity" "todo_api:7" "$(task_source_identity '{"taskSourceType":"todo_api","taskSourceId":"7"}')"

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
