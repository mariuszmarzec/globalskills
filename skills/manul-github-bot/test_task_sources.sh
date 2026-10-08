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
{"repositories":["legacy/repo"],"taskSources":[{"type":"github_issues","enabled":true,"repositories":["owner/issues"]},{"type":"jira_tasks","enabled":false,"baseUrl":"http://todo.local"}]}
JSON
sources="$(task_source_configured_sources "$WORK/config.json")"
assert_contains "enabled GitHub source appears" "$sources" '"type":"github_issues"'
assert_not_contains "disabled Jira source is omitted" "$sources" '"type":"jira_tasks"'

cat >"$WORK/legacy.json" <<'JSON'
{"repositories":["owner/legacy"]}
JSON
legacy="$(task_source_configured_sources "$WORK/legacy.json")"
assert_contains "legacy config maps to GitHub Issues" "$legacy" '"type":"github_issues"'
assert_contains "legacy repository preserved" "$legacy" "owner/legacy"

cat >"$WORK/multi.json" <<'JSON'
{"taskSources":[{"type":"github_issues","enabled":true,"repositories":["owner/b"]},{"type":"github_issues","enabled":true,"repositories":["owner/a","owner/b"]},{"type":"jira_tasks","enabled":true,"baseUrl":"http://todo.local"}]}
JSON
multi="$(task_source_configured_sources "$WORK/multi.json")"
count="$(printf "%s\n" "$multi" | wc -l | tr -d " ")"
assert_eq "multiple source entries are preserved" "3" "$count"
assert_contains "first GitHub repository preserved" "$multi" "owner/b"
assert_contains "second GitHub repository preserved" "$multi" "owner/a"
assert_contains "Jira source is preserved when enabled" "$multi" '"type":"jira_tasks"'

cat >"$WORK/jira.json" <<'JSON'
{"type":"jira_tasks","enabled":true,"baseUrl":"http://jira.local","userEnv":"MANUL_JIRA_USER","passwordEnv":"MANUL_JIRA_PASSWORD","jql":"project = DEMO"}
JSON
cat >"$BIN/curl" <<'CURL'
#!/usr/bin/env bash
cat <<'JSON'
{"issues":[{"id":"10001","key":"DEMO-7","fields":{"summary":"Fix sync","description":"/manul Fix sync","created":"2026-10-08T10:00:00.000+0000","updated":"2026-10-08T11:00:00.000+0000","status":{"name":"To Do"},"project":{"key":"DEMO"},"issuetype":{"name":"Task"}}},{"id":"10002","key":"DEMO-8","fields":{"summary":"Do not run","description":"ordinary Jira task","status":{"name":"To Do"},"project":{"key":"DEMO"},"issuetype":{"name":"Task"}}}]}
JSON
CURL
chmod +x "$BIN/curl"
export PATH="$BIN:$PATH"
export MANUL_JIRA_USER="jira-user"
export MANUL_JIRA_PASSWORD="jira-password"
source "$SCRIPT_DIR/task-source-jira-tasks.sh"
jira_source="$(cat "$WORK/jira.json")"
jira_tasks="$(task_source_jira_tasks_poll "$jira_source")"
assert_contains "Jira trigger is discovered" "$jira_tasks" '"taskSourceType":"jira_task"'
assert_contains "Jira issue key is stable id" "$jira_tasks" '"taskSourceId":"DEMO-7"'
assert_contains "Jira browse url is normalized" "$jira_tasks" '"https://jira.example.com/browse/DEMO-7"'
assert_not_contains "Jira task without trigger is ignored" "$jira_tasks" '"taskSourceId":"DEMO-8"'
assert_not_contains "Jira user is not emitted" "$jira_tasks" "jira-user"
assert_not_contains "Jira password is not emitted" "$jira_tasks" "jira-password"
if task_source_type_is_supported github_pr; then fail "PR must not be a task source"; else ok "PR is not a task source"; fi
assert_eq "stable Jira source identity" "jira_task:DEMO-7" "$(task_source_identity '{"taskSourceType":"jira_task","taskSourceId":"DEMO-7"}')"
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
