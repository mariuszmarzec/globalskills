#!/usr/bin/env bash
# Regression tests for the additive OpenCode permissions helper.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME/.config/opencode" "$TMP/bin"
CONFIG="$TMP/custom opencode config.json"
MOCK_BIN="$TMP/bin/opencode"

cat >"$CONFIG" <<'JSON'
{
  "model": "provider/model",
  "theme": "preserve-me",
  "permission": {
    "external_directory": {
      "/operator/custom/**": "allow"
    },
    "read": "allow",
    "edit": "ask",
    "list": "ask",
    "glob": "ask",
    "grep": "ask"
  }
}
JSON
chmod 640 "$CONFIG"

cat >"$MOCK_BIN" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "debug" ] && [ "${2:-}" = "config" ]; then
  cat "$OPENCODE_CONFIG"
  exit 0
fi
echo "unexpected OpenCode command: $*" >&2
exit 2
MOCK
chmod +x "$MOCK_BIN"

export OPENCODE_CONFIG="$CONFIG" OPENCODE_BIN="$MOCK_BIN"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_jq() {
  local description="$1" expression="$2"
  jq -e "$expression" "$CONFIG" >/dev/null || fail "$description"
  echo "PASS: $description"
}

bash "$SCRIPT_DIR/opencode-permissions.sh"

assert_jq "non-Manul provider fields are preserved" '.model == "provider/model" and .theme == "preserve-me"'
assert_jq "existing custom external-directory rule is preserved" '.permission.external_directory["/operator/custom/**"] == "allow"'
assert_jq "temporary workspace access remains allowlisted" '.permission.external_directory["/tmp/**"] == "allow"'
assert_jq "diagnostic scratch access remains allowlisted" '.permission.external_directory["/tmp/manul-diagnostics/**"] == "allow"'
assert_jq "Manul logs are externally reachable only under the narrow logs path" '.permission.external_directory["~/.manul/logs/**"] == "allow"'
assert_jq "log read/list/search are allowed" '.permission.read["~/.manul/logs/**"] == "allow" and .permission.list["~/.manul/logs/**"] == "allow" and .permission.glob["~/.manul/logs/**"] == "allow" and .permission.grep["~/.manul/logs/**"] == "allow"'
assert_jq "log edits remain denied" '.permission.edit["~/.manul/logs/**"] == "deny"'
assert_jq "Gradle artifact access remains narrowly scoped" '.permission.external_directory["~/.gradle/caches/modules-2/files-2.1/**"] == "allow"'
[ "$(stat -c '%a' "$CONFIG")" = "640" ] || fail "custom provider config file mode was not preserved"
echo "PASS: provider configuration file mode is preserved"

FIRST_HASH="$(sha256sum "$CONFIG" | awk '{print $1}')"
bash "$SCRIPT_DIR/opencode-permissions.sh"
SECOND_HASH="$(sha256sum "$CONFIG" | awk '{print $1}')"
[ "$FIRST_HASH" = "$SECOND_HASH" ] || fail "permissions helper is not idempotent"
echo "PASS: repeated permission setup is idempotent"

echo "All OpenCode permission helper tests passed."
