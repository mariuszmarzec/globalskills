#!/usr/bin/env bash
# Offline integration tests for the OpenCode ACP Caracal wrapper.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER="$SCRIPT_DIR/opencode-acp-caracal.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
BIN="$TMP/bin"
CARACAL="$HOME_DIR/.caracal"
OPENCODE_CONFIG="$HOME_DIR/.config/opencode/opencode.json"
mkdir -p "$HOME_DIR/.config/opencode" "$CARACAL/bin" "$CARACAL/venv/bin" "$CARACAL/config" "$BIN"
chmod 700 "$HOME_DIR" "$CARACAL" "$CARACAL/config"

# Caracal env provider (the wrapper sources this)
cat >"$CARACAL/env.sh" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
CARACAL_HOME="${CARACAL_HOME:-$HOME/.caracal}"
export CARACAL_HOME
caracal_load_token() {
    local secrets_dir secrets_file python3
    secrets_dir="$CARACAL_HOME/config"
    secrets_file="$secrets_dir/secrets.yaml"
    python3="$CARACAL_HOME/venv/bin/python"
    [ -x "$python3" ] && [ -f "$secrets_file" ] || return 1
    "$python3" - "$secrets_file" <<'PY'
import sys
from pathlib import Path
from caracal_rag.config import load_secrets
token = load_secrets(Path(sys.argv[1])).get("access_token", "")
if not token:
    raise SystemExit("Caracal access token is missing")
print(token, end="")
PY
}
caracal_validate_token() {
    local token="${CARACAL_ACCESS_TOKEN:-}"
    [ -n "$token" ] || return 1
    [[ "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]]
}
caracal_resolve_url() {
    local current_url="${CARACAL_MCP_URL:-}"
    case "$current_url" in
        "" | http://127.0.0.1:0/* | http://127.0.0.1:* | \
        http://localhost:* | http://[::1]:*)
            local cli check_output mcp_host mcp_port mcp_path
            cli="$CARACAL_HOME/bin/caracal-rag"
            [ -x "$cli" ] || return 1
            check_output="$("$cli" check 2>/dev/null)" || return 1
            mcp_host="$(printf '%s\n' "$check_output" | sed -n 's/.*mcp_host=\([^ ]*\).*/\1/p' | tail -n 1)"
            mcp_port="$(printf '%s\n' "$check_output" | sed -n 's/.*mcp_port=\([^ ]*\).*/\1/p' | tail -n 1)"
            mcp_path="$(printf '%s\n' "$check_output" | sed -n 's/.*mcp_path=\([^ ]*\).*/\1/p' | tail -n 1)"
            [ "$mcp_host" = "127.0.0.1" ] || return 1
            [[ "$mcp_port" =~ ^[0-9]{1,5}$ ]] || return 1
            (( mcp_port >= 1 && mcp_port <= 65535 )) || return 1
            [[ "$mcp_path" =~ ^/[A-Za-z0-9/_-]+$ ]] || return 1
            CARACAL_MCP_URL="http://127.0.0.1:$mcp_port$mcp_path"
            ;;
        http://* | https://*) ;;
        *) return 1 ;;
    esac
    export CARACAL_MCP_URL
}
caracal_require_live() {
    if [ -z "${CARACAL_ACCESS_TOKEN:-}" ]; then
        CARACAL_ACCESS_TOKEN="$(caracal_load_token)" || return 1
    fi
    caracal_validate_token || return 1
    caracal_resolve_url || return 1
    export CARACAL_ACCESS_TOKEN
}
if [ -z "${CARACAL_ACCESS_TOKEN:-}" ]; then
    if ! CARACAL_ACCESS_TOKEN="$(caracal_load_token)"; then
        echo "caracal-env: ERROR: Caracal access token is unavailable at $CARACAL_HOME/config/secrets.yaml" >&2
        return 1
    fi
fi
if ! caracal_validate_token; then
    echo "caracal-env: ERROR: Caracal token contains unsupported characters (must be safe for dotenv files)" >&2
    return 1
fi
export CARACAL_ACCESS_TOKEN
if [ "${CARACAL_RESOLVE_LIVE:-}" = "1" ]; then
    caracal_require_live || {
        echo "caracal-env: ERROR: Caracal MCP is not reachable (caracal-rag check failed); refusing to start OpenCode" >&2
        return 1
    }
fi
PROVIDER
chmod +x "$CARACAL/env.sh"

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
[ "${1:-}" = "check" ] || exit 2
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
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  [ "${CARACAL_MCP_URL:-}" = "http://127.0.0.1:3510/mcp" ] || exit 71
  [ "${CARACAL_ACCESS_TOKEN:-}" = "test-caracal-token" ] || exit 72
  [ "${OPENCODE_CONFIG:-}" = "${EXPECTED_CONFIG:-}" ] || exit 73
  jq -e '
    .mcp["caracal-rag"].url == "{env:CARACAL_MCP_URL}"
    and .mcp["caracal-rag"].headers.Authorization == "Bearer {env:CARACAL_ACCESS_TOKEN}"
    and .mcp["caracal-rag"].enabled == true
  ' "$OPENCODE_CONFIG" >/dev/null
  : > "${PREFLIGHT_FILE:?}"
  if [ "${MOCK_MCP_STATE:-connected}" = "connected" ]; then
    printf '%s\n' 'caracal-rag connected'
    exit 0
  fi
  printf '%s\n' 'caracal-rag failed'
  exit 1
fi
if [ "${1:-}" = "acp" ]; then
  printf '%s\n' "$*" > "${ACP_ARGS_FILE:?}"
  printf '%s\n' "$CARACAL_MCP_URL" "$CARACAL_ACCESS_TOKEN" "$OPENCODE_CONFIG" > "${ACP_ENV_FILE:?}"
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
  CARACAL_ACCESS_TOKEN="" \
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
