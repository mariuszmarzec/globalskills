#!/usr/bin/env bash
# Regression tests for aicode's one-time shared OpenCode environment refresh.
# Every test uses a fake CLI and isolated service registration.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HELPER="$ROOT/aicode/opencode-service-lifecycle.sh"
READINESS="$ROOT/aicode/opencode-mcp-readiness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }

bash -n "$HELPER" || fail "service lifecycle helper syntax"
bash -n "$READINESS" || fail "MCP readiness helper syntax"

mkdir -p "$TMP/bin" "$TMP/state"
export PATH="$TMP/bin:$PATH"
export AICODE_OPENCODE_SERVICE_INFO_FILE="$TMP/state/service.json"
export MOCK_STATE_FILE="$TMP/state/mcp-state"
export MOCK_RESTART_FILE="$TMP/state/restarts"
export MOCK_ACTIVE_FILE="$TMP/state/active.json"
export MOCK_PTY_FILE="$TMP/state/pty.json"
export MOCK_SS_BUSY=0
export OPENCODE_MCP_WAIT_TIMEOUT=2 OPENCODE_MCP_PROBE_TIMEOUT=1 OPENCODE_MCP_RETRY_INTERVAL=1
export AICODE_OPENCODE_EXISTING_SERVICE_WAIT_SECONDS=1
export AICODE_OPENCODE_NEW_SERVICE_WAIT_SECONDS=3
export AICODE_OPENCODE_SERVICE_RESTART_TIMEOUT_SECONDS=5

cat > "$TMP/bin/ps" <<'MOCK_PS'
#!/usr/bin/env bash
case "$*" in
  *"stat="*) printf '%s\n' 'S' ;;
  *"args="*) printf '%s\n' '/home/test/.opencode/bin/opencode serve --service' ;;
  *) exit 2 ;;
esac
MOCK_PS
cat > "$TMP/bin/ss" <<'MOCK_SS'
#!/usr/bin/env bash
if [ "${MOCK_SS_BUSY:-0}" = "1" ]; then
  printf '%s\n' 'ESTAB 0 0 127.0.0.1:49374 127.0.0.1:41234'
fi
MOCK_SS
cat > "$TMP/bin/opencode" <<'MOCK_OPENCODE'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "mcp list")
    state="$(cat "$MOCK_STATE_FILE")"
    if [ "$state" = "connected" ]; then
      echo "caracal-rag connected"
      exit 0
    fi
    echo "caracal-rag disconnected"
    exit 1
    ;;
  "api get")
    case "$3" in
      "/api/session/active")
        cat "$MOCK_ACTIVE_FILE"
        ;;
      /api/pty\?*)
        cat "$MOCK_PTY_FILE"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  "service restart")
    printf '%s\n' restarted >> "$MOCK_RESTART_FILE"
    printf '%s\n' connected > "$MOCK_STATE_FILE"
    ;;
  *)
    exit 2
    ;;
esac
MOCK_OPENCODE
chmod +x "$TMP/bin/ps" "$TMP/bin/ss" "$TMP/bin/opencode"

write_service() {
  printf '{"pid":%s,"url":"http://127.0.0.1:49374"}\n' "$$" > "$AICODE_OPENCODE_SERVICE_INFO_FILE"
}
reset_fixture() {
  printf '%s\n' disconnected > "$MOCK_STATE_FILE"
  : > "$MOCK_RESTART_FILE"
  printf '%s\n' '{"data":{}}' > "$MOCK_ACTIVE_FILE"
  printf '%s\n' '{"data":[]}' > "$MOCK_PTY_FILE"
  export MOCK_SS_BUSY=0
  write_service
}

source "$HELPER"

# With no pre-existing service, the first mcp list starts a fresh server from
# aicode's already-loaded environment. It must not perform a redundant restart.
rm -f "$AICODE_OPENCODE_SERVICE_INFO_FILE"
printf '%s\n' connected > "$MOCK_STATE_FILE"
aicode_opencode_caracal_service_ready "$ROOT/aicode" "$TMP/bin/opencode" >/dev/null 2>&1 ||
  fail "new shared service did not become ready"
[ ! -s "$MOCK_RESTART_FILE" ] || fail "new service was unnecessarily restarted"
ok "new shared service inherits aicode's current environment without a restart"

# Existing service, disconnected MCP, no sessions/terminals/clients: restart
# once from aicode's current shell and verify the actual MCP connection.
reset_fixture
aicode_opencode_caracal_service_ready "$ROOT/aicode" "$TMP/bin/opencode" >/dev/null 2>&1 ||
  fail "idle stale service was not refreshed"
[ "$(wc -l < "$MOCK_RESTART_FILE" | tr -d ' ')" = "1" ] || fail "idle stale service was not restarted exactly once"
[ "$(cat "$MOCK_STATE_FILE")" = "connected" ] || fail "MCP did not reconnect after service restart"
ok "idle stale service is restarted once and Caracal readiness is re-verified"

# Never restart while an agent session is active.
reset_fixture
printf '%s\n' '{"data":{"ses_busy":{"type":"running"}}}' > "$MOCK_ACTIVE_FILE"
if aicode_opencode_caracal_service_ready "$ROOT/aicode" "$TMP/bin/opencode" >/dev/null 2>&1; then
  fail "active session should block the service restart"
fi
[ ! -s "$MOCK_RESTART_FILE" ] || fail "service restarted while an agent session was active"
ok "active OpenCode agent sessions prevent service restart"

# Never restart while a persistent terminal is running in the aicode directory.
reset_fixture
printf '%s\n' '{"data":[{"id":"pty_1","status":"running"}]}' > "$MOCK_PTY_FILE"
if aicode_opencode_caracal_service_ready "$ROOT/aicode" "$TMP/bin/opencode" >/dev/null 2>&1; then
  fail "running PTY should block the service restart"
fi
[ ! -s "$MOCK_RESTART_FILE" ] || fail "service restarted while a persistent terminal was running"
ok "running OpenCode terminals prevent service restart"

# A connected TUI/browser client is also a hard stop because service restart
# would drop the server-owned terminal/process state.
reset_fixture
export MOCK_SS_BUSY=1
if aicode_opencode_caracal_service_ready "$ROOT/aicode" "$TMP/bin/opencode" >/dev/null 2>&1; then
  fail "connected client should block the service restart"
fi
[ ! -s "$MOCK_RESTART_FILE" ] || fail "service restarted while an OpenCode client was connected"
ok "connected OpenCode clients prevent service restart"

# Unknown API responses fail closed instead of making a potentially unsafe restart.
reset_fixture
printf '%s\n' '{"unexpected":[]}' > "$MOCK_ACTIVE_FILE"
if aicode_opencode_caracal_service_ready "$ROOT/aicode" "$TMP/bin/opencode" >/dev/null 2>&1; then
  fail "invalid active-session response should block restart"
fi
[ ! -s "$MOCK_RESTART_FILE" ] || fail "service restarted after an invalid session response"
ok "unknown OpenCode state prevents service restart"

# The service lifecycle helper contains no private-runtime mode and has no
# relationship to Manul task execution.
if grep -Fq -- '--standalone' "$HELPER"; then
  fail "service lifecycle helper must never reintroduce --standalone"
fi
if grep -Fq 'service restart' "$ROOT/../manul/skills/manul-github-bot/opencode-adapter.sh" 2>/dev/null; then
  fail "Manul task adapter must not restart the shared OpenCode service per task"
fi
ok "service restart is limited to aicode startup, never Manul task execution"

echo "All OpenCode service lifecycle tests passed."
