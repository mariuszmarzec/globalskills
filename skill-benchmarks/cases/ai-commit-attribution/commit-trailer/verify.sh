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

hello_ok() { [ "$(cat "$WORKSPACE/hello.txt")" = "hello benchmark" ]; }
commit_count_ok() { [ "$(git -C "$WORKSPACE" rev-list --count HEAD)" = "2" ]; }
message_ok() { [ "$(git -C "$WORKSPACE" log -1 --pretty=%s)" = "benchmark: update hello" ]; }
author_ok() { [ "$(git -C "$WORKSPACE" log -1 --format='%an <%ae>')" = "Benchmark User <benchmark@example.invalid>" ]; }
config_ok() {
  [ "$(git -C "$WORKSPACE" config --local user.name)" = "Benchmark User" ] &&
  [ "$(git -C "$WORKSPACE" config --local user.email)" = "benchmark@example.invalid" ]
}
trailer_ok() {
  git -C "$WORKSPACE" log -1 --format=%B | grep -Fq "Co-authored-by: OpenCode <opencode@ai.local>"
}
json_bool() {
  printf '%s' "$1"
}

h=false; hello_ok && h=true || true
c=false; commit_count_ok && c=true || true
m=false; message_ok && m=true || true
a=false; author_ok && a=true || true
g=false; config_ok && g=true || true
t=false; trailer_ok && t=true || true

passed=false
if [ "$h" = true ] && [ "$c" = true ] && [ "$m" = true ] && [ "$a" = true ] && [ "$g" = true ] && [ "$t" = true ]; then
  passed=true
fi

printf '{"passed":%s,"mode":"%s","checks":[' "$(json_bool "$passed")" "$MODE"
printf '{"name":"file-content","passed":%s},' "$(json_bool "$h")"
printf '{"name":"new-commit","passed":%s},' "$(json_bool "$c")"
printf '{"name":"commit-message","passed":%s},' "$(json_bool "$m")"
printf '{"name":"author-preserved","passed":%s},' "$(json_bool "$a")"
printf '{"name":"git-config-preserved","passed":%s},' "$(json_bool "$g")"
printf '{"name":"opencode-trailer","passed":%s}]}' "$(json_bool "$t")"
printf '\n'

if [ "$passed" = true ]; then
  exit 0
fi
exit 1
