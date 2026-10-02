#!/usr/bin/env bash
set -euo pipefail

WORKSPACE=""
MODE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      WORKSPACE="$2"; shift 2 ;;
    --mode)
      MODE="$2"; shift 2 ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2 ;;
  esac
done

[ -n "$WORKSPACE" ] || { echo "missing --workspace" >&2; exit 2; }
[ -n "$MODE" ] || { echo "missing --mode" >&2; exit 2; }

hello_actual="$(cat "$WORKSPACE/hello.txt" 2>/dev/null || true)"
commit_count_actual="$(git -C "$WORKSPACE" rev-list --count HEAD 2>/dev/null || true)"
message_actual="$(git -C "$WORKSPACE" log -1 --pretty=%s 2>/dev/null || true)"
author_actual="$(git -C "$WORKSPACE" log -1 --format='%an <%ae>' 2>/dev/null || true)"
name_actual="$(git -C "$WORKSPACE" config --local user.name 2>/dev/null || true)"
email_actual="$(git -C "$WORKSPACE" config --local user.email 2>/dev/null || true)"

hello_ok=false
commit_count_ok=false
message_ok=false
author_ok=false
config_ok=false
trailer_ok=false

[ "$hello_actual" = "hello benchmark" ] && hello_ok=true || true
[ "$commit_count_actual" = "2" ] && commit_count_ok=true || true
[ "$message_actual" = "benchmark: update hello" ] && message_ok=true || true
[ "$author_actual" = "Benchmark User <benchmark@example.invalid>" ] && author_ok=true || true
[ "$name_actual" = "Benchmark User" ] && [ "$email_actual" = "benchmark@example.invalid" ] && config_ok=true || true
git -C "$WORKSPACE" log -1 --format=%B 2>/dev/null | grep -Fq "Co-authored-by: OpenCode <opencode@ai.local>" && trailer_ok=true || true

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}

passed=false
if [ "$hello_ok" = true ] && [ "$commit_count_ok" = true ] && [ "$message_ok" = true ] &&
   [ "$author_ok" = true ] && [ "$config_ok" = true ] && [ "$trailer_ok" = true ]; then
  passed=true
fi

printf '{"passed":%s,"mode":"%s","checks":[' "$passed" "$MODE"
printf '{"name":"file-content","passed":%s,"expected":"hello benchmark","actual":"%s","evidence":"cat hello.txt"},' "$hello_ok" "$(json_escape "$hello_actual")"
printf '{"name":"new-commit","passed":%s,"expected":"2 commits","actual":"%s","evidence":"git rev-list --count HEAD"},' "$commit_count_ok" "$(json_escape "$commit_count_actual")"
printf '{"name":"commit-message","passed":%s,"expected":"benchmark: update hello","actual":"%s","evidence":"git log -1 --pretty=%%s"},' "$message_ok" "$(json_escape "$message_actual")"
printf '{"name":"author-preserved","passed":%s,"expected":"Benchmark User <benchmark@example.invalid>","actual":"%s","evidence":"git log -1 --format=%%an <%%ae>"},' "$author_ok" "$(json_escape "$author_actual")"
printf '{"name":"git-config-preserved","passed":%s,"expected":"Benchmark User <benchmark@example.invalid>","actual":"%s <%s>","evidence":"git config --local user.name/user.email"},' "$config_ok" "$(json_escape "$name_actual")" "$(json_escape "$email_actual")"
printf '{"name":"opencode-trailer","passed":%s,"expected":"Co-authored-by trailer present","actual":"%s","evidence":"git log -1 --format=%%B"}]}' "$trailer_ok" "$([ "$trailer_ok" = true ] && echo present || echo missing)"
printf '\n'

if [ "$passed" = true ]; then
  exit 0
fi
exit 1
