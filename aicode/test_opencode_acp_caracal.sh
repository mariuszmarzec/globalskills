#!/usr/bin/env bash
# Offline integration tests for the OpenCode ACP Caracal wrapper.
set -euo pipefail

ROOT="$(cd "$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/aicode/opencode-acp-caracal.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
BIN="$TMP/bin"
CARACAL="$HOME_DIR/.caracal"
OPENCODE_CONFIG="$HOME_DIR/.config/opencode/opencode.json"
mkdir -p "$HOME_DIR/.config/opencode" "$CARACAL/bin" "$CARACAL/venv/bin" "$CARACAL/config" "$BIN"
chmod 700 "$HOME_DIR" "$CARACAL" "$CARACAL/config"

cat >"$OPENCODE_CONFIG" <<'JSON'
{
  "mcp": {
    "caracal-rag": {
      "type": "remote",
      "url": "{env:CARACAL_MCP_URL}",
      "oauth": false,
      "enabled": true,
      "headers": {
        "Authorization": "Bearer {env:CARACAL_ACCESS_TOKEN}"
      }
    }
  }
}
JSON
printf '%s\n' 'access_token: test-placeholder' > "$CARACAL/config/secrets.yaml"
chmod 600 "$CARACAL/config/secrets.yaml"

cat >"$CARACAL/bin/caracal-rag" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = "check" ] || exit 2
printf '%s\n' 'status=ok mcp_host=127.0.0.1 mcp_port=3510 mcp_path=/mcp'
MOCK
chmod +x "$CARACAL/bin/caracal-rag"

# The fake venv Python consumes the loader program and returns the test token.
cat >"$CARACAL/venv/bin/python" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' 'test-caracal-token'
MOCK
chmod +x "$CARACAL/venv/bin/python"

cat >"$BIN/opencode" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "mcp" ] && [ "\${2:-}" = "list" ]; then
  [ "\${CARACAL_MCP_URL:-}" = "http://127.0.0.1:3510/mcp" ] || exit 71
  [ "\${CARACAL_ACCESS_TOKEN:-}" = "test-caracal-token" ] || exit 72
  [ "\${OPENCODE_CONFIG:-}" = "\${EXPECTED_CONFIG:-}" ] || exit 73
  jq -e '
    .mcp["caracal-rag"].url == "{env:CARACAL_MCP_URL}"
    and .mcp["caracal-rag"].headers.Authorization == "Bearer {env:CARACAL_ACCESS_TOKEN}"
    and .mcp["caracal-rag"].enabled == true
  ' "$OPENCODE_CONFIG" >/dev/null
  : > "\${PREFLIGHT_FILE:?}"
  if [ "\${MOCK_MCP_STATE:-connected}" = "connected" ]; then
    printf '%s\n' 'caracal-rag connected'
    exit 0
  fi
  printf '%s\n' 'caracal-rag failed'
  exit 1
fi
if [ "\${1:-}" = "acp" ]; then
  printf '%s\n' "$*" > "\${ACP_ARGS_FILE:?}"
  printf '%s\n' "$CARACAL_MCP_URL" "$CARACAL_ACCESS_TOKEN" "$OPENCODE_CONFIG" > "\${ACP_ENV_FILE:?}"
  exit 0
fi
exit 2
MOCK
chmod +x "$BIN/opencode"

run_wrapper() {
  local state="$1"
  HOME="$HOME_DIR" \
  PATH="$BIN:/usr/bin:/bin" \
  CARACAL_HOME="$CARACAL" \
  CARACAL_MCP_URL="http://127.0.0.1:0/mcp" \
  OPENCODE_CONFIG="$OPENCODE_CONFIG" \
  OPENCODE_BIN="$BIN/opencode" \
  EXPECTED_CONFIG="$OPENCODE_CONFIG" \
  MOCK_MCP_STATE="$state" \
  PREFLIGHT_FILE="$TMP/preflight" \
  ACP_ARGS_FILE="$TMP/acp-args" \
  ACP_ENV_FILE="$TMP/acp-env" \
  bash "$WRAPPER" acp
}

echo "=== OpenCode ACP Caracal Wrapper Tests ==="
if run_wrapper connected >"$TMP/stdout" 2>"$TMP/stderr"; then
  grep -qx 'acp' "$TMP/acp-args" || { echo "FAIL: ACP arguments were not forwarded" >&2; exit 1; }
  [ -f "$TMP/preflight" ] || { echo "FAIL: MCP preflight did not run" >&2; exit 1; }
  grep -Fxq 'http://127.0.0.1:3510/mcp' "$TMP/acp-env" || { echo "FAIL: current Caracal endpoint was not passed to ACP" >&2; exit 1; }
  grep -Fxq 'test-caracal-token' "$TMP/acp-env" || { echo "FAIL: current token was not passed to ACP" >&2; exit 1; }
  grep -Fxq "$OPENCODE_CONFIG" "$TMP/acp-env" || { echo "FAIL: OpenCode config path was not passed to ACP" >&2; exit 1; }
  echo "PASS: live Caracal MCP is verified before starting ACP"
  echo "PASS: resolved endpoint, current token, and config reach OpenCode ACP"
else
  cat "$TMP/stderr" >&2
  echo "FAIL: wrapper rejected a connected Caracal MCP" >&2
  exit 1
fi

rm -f "$TMP/preflight" "$TMP/acp-args" "$TMP/acp-env"
set +e
run_wrapper disconnected >"$TMP/stdout" 2>"$TMP/stderr"
rc=$?
set -e
[ "$rc" -eq 78 ] || { echo "FAIL: disconnected MCP returned $rc, expected 78" >&2; exit 1; }
[ ! -f "$TMP/acp-args" ] || { echo "FAIL: ACP launched while Caracal was disconnected" >&2; exit 1; }
echo "PASS: disconnected Caracal MCP blocks ACP launch"

echo "All OpenCode ACP Caracal wrapper tests passed."
