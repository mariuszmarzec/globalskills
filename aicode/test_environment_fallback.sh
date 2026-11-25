#!/usr/bin/env bash
# Regression tests for the Zsh-first environment fallback loader.

set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/aicode/environment-fallback.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
assert_no_loader_temp() {
  local leftover
  leftover="$(find "$TMP" -maxdepth 1 -type f -name 'aicode-env.*' -print -quit)"
  [ -z "$leftover" ] || fail "environment loader left a private temporary file behind: $leftover"
}

[ -r "$HELPER" ] || fail "environment fallback helper is missing"
bash -n "$HELPER" || fail "environment fallback helper has invalid Bash syntax"

cat > "$TMP/legacy.env" <<'ENV'
# These values are old copies and must not replace Zsh exports.
PATH=/legacy/bin:/usr/bin:/bin
OPENCODE_API_KEY=legacy-console-key
LITELLM_MASTER_KEY=legacy-litellm-key

# Unset integration-only values may still be read as compatibility fallbacks.
FALLBACK_INTEGRATION_VALUE='loaded from private fallback'
ENV

result_file="$TMP/operator-result.txt"
PATH="$TMP/operator-bin:/usr/bin:/bin" \
OPENCODE_API_KEY="console-key-from-zshrc" \
LITELLM_MASTER_KEY="litellm-key-from-zshrc" \
bash -c '
  set -euo pipefail
  . "$1"
  aicode_load_environment_fallback "$2"
  printf "%s\n%s\n%s\n%s\n" "$PATH" "$OPENCODE_API_KEY" "$LITELLM_MASTER_KEY" "$FALLBACK_INTEGRATION_VALUE"
' _ "$HELPER" "$TMP/legacy.env" > "$result_file"
result="$(cat "$result_file")"
assert_no_loader_temp
expected="$TMP/operator-bin:/usr/bin:/bin
console-key-from-zshrc
litellm-key-from-zshrc
loaded from private fallback"
[ "$result" = "$expected" ] || fail "Zsh exports or PATH were overwritten by a fallback file"
ok "Zsh PATH and provider credentials win over legacy fallback values"

fallback_result_file="$TMP/fallback-only-result.txt"
env -u OPENCODE_API_KEY -u LITELLM_MASTER_KEY \
  PATH="$PATH" bash -c '
    set -euo pipefail
    . "$1"
    aicode_load_environment_fallback "$2"
    printf "%s\n%s\n%s\n" "$OPENCODE_API_KEY" "$LITELLM_MASTER_KEY" "$FALLBACK_INTEGRATION_VALUE"
  ' _ "$HELPER" "$TMP/legacy.env" > "$fallback_result_file"
fallback_only="$(cat "$fallback_result_file")"
assert_no_loader_temp
expected_fallback="legacy-console-key
legacy-litellm-key
loaded from private fallback"
[ "$fallback_only" = "$expected_fallback" ] || fail "Compatibility fallback values were not loaded when no shell export exists"
ok "Unexported legacy values remain available only as fallback"

# A fallback file must not execute shell statements: accept simple assignments,
# not arbitrary commands embedded in the file.
cat > "$TMP/untrusted.env" <<ENV
SHOULD_NOT_BE_SET=ok
touch "$TMP/command-executed"
BAD_ASSIGNMENT=inline; touch "$TMP/inline-command-executed"
ENV
env -u SHOULD_NOT_BE_SET -u BAD_ASSIGNMENT bash -c '
  set -euo pipefail
  . "$1"
  aicode_load_environment_fallback "$2"
  [ "${SHOULD_NOT_BE_SET:-}" = "ok" ]
  [ -z "${BAD_ASSIGNMENT:-}" ]
' _ "$HELPER" "$TMP/untrusted.env" || fail "simple fallback assignment was not loaded or inline command was accepted"
[ ! -e "$TMP/command-executed" ] || fail "fallback loader executed an arbitrary shell command"
[ ! -e "$TMP/inline-command-executed" ] || fail "fallback loader executed a command after an inline assignment"
ok "Fallback loader ignores command lines and assignments containing shell operators"

echo "All environment fallback tests passed."
