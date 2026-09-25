#!/usr/bin/env bash
# test_manul_environment.sh — provider environment/bootstrap and lifecycle tests.
#
# These tests use isolated temporary runtimes only. No production ~/.manul,
# OpenClaw state, cron, or GitHub state is touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_file_mode_600() {
  local file="$1"
  local mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
  [ "$mode" = "600" ] && ok "Environment file is mode 600" || fail "Environment file mode is $mode (expected 600)"
}

echo "=== Manul Environment Tests ==="
echo "Canonical source: $SCRIPT_DIR"
echo

# ---------------------------------------------------------------------------
# 0. Integration wiring.
# ---------------------------------------------------------------------------
grep -q 'manul-env.sh' "$SCRIPT_DIR/install-manul-symlinks.sh"   && ok "Symlink installer deploys manul-env.sh"   || fail "Symlink installer does not deploy manul-env.sh"

grep -q 'manul_env_bootstrap' "$SCRIPT_DIR/install-manul.sh"   && ok "Installer bootstraps the operator environment"   || fail "Installer does not bootstrap the operator environment"

grep -q 'manul_env_load' "$SCRIPT_DIR/manul-daemon.sh"   && ok "Daemon loads the runtime operator environment"   || fail "Daemon does not load the runtime operator environment"

grep -q 'manul_env_load' "$SCRIPT_DIR/watchdog.sh"   && ok "Watchdog loads the runtime operator environment"   || fail "Watchdog does not load the runtime operator environment"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RUNTIME="$TMP/runtime"
OPENCLAW_STATE_DIR="$TMP/openclaw state"
OPENCLAW_CONFIG_PATH="$TMP/openclaw/config with spaces.json"
OPENCLAW_BIN="$TMP/bin/openclaw-custom"
OPENCODE_BIN="$TMP/bin/opencode-custom"
UNSAFE_SECRET="must-not-be-copied"

export OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_BIN OPENCODE_BIN UNSAFE_SECRET

ENV_FILE="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$RUNTIME")"

[ -f "$ENV_FILE" ] && ok "Bootstrap creates ~/.manul/.env equivalent" || fail "Bootstrap did not create environment file"
assert_file_mode_600 "$ENV_FILE"

if ! grep -q '^OPENCLAW_STATE_DIR=' "$ENV_FILE" ||
   ! grep -q '^OPENCLAW_CONFIG_PATH=' "$ENV_FILE" ||
   ! grep -q '^OPENCLAW_BIN=' "$ENV_FILE" ||
   ! grep -q '^OPENCODE_BIN=' "$ENV_FILE"; then
  fail "Bootstrap did not persist all supported provider variables"
else
  ok "Bootstrap persists supported provider variables"
fi

if grep -q 'UNSAFE_SECRET' "$ENV_FILE"; then
  fail "Bootstrap copied an arbitrary environment variable"
else
  ok "Bootstrap does not copy arbitrary environment variables"
fi

if (
  unset OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_BIN OPENCODE_BIN
  source "$ENV_FILE"
  [ "$OPENCLAW_STATE_DIR" = "$TMP/openclaw state" ] &&
  [ "$OPENCLAW_CONFIG_PATH" = "$TMP/openclaw/config with spaces.json" ] &&
  [ "$OPENCLAW_BIN" = "$TMP/bin/openclaw-custom" ] &&
  [ "$OPENCODE_BIN" = "$TMP/bin/opencode-custom" ]
); then
  ok "Bootstrap shell-quotes provider values correctly"
else
  fail "Bootstrap did not preserve provider values when reloaded"
fi

PRESERVE="$TMP/preserve"
mkdir -p "$PRESERVE"
cat > "$PRESERVE/.env" <<'EOF'
OPENCLAW_STATE_DIR=/operator/chosen/state
EOF
chmod 600 "$PRESERVE/.env"

OPENCLAW_STATE_DIR="/installer/current/state"
OPENCLAW_CONFIG_PATH="/installer/current/config.json"
export OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH
ENV_FILE2="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$PRESERVE")"

if (
  unset OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH
  source "$ENV_FILE2"
  [ "$OPENCLAW_STATE_DIR" = "/operator/chosen/state" ] &&
  [ "$OPENCLAW_CONFIG_PATH" = "/installer/current/config.json" ]
); then
  ok "Existing operator provider configuration is preserved"
else
  fail "Bootstrap overwrote or failed to append provider configuration"
fi

INVALID="$TMP/invalid"
mkdir -p "$INVALID"
printf 'THIS IS NOT VALID SHELL\n' > "$INVALID/.env"

set +e
INVALID_RC=0
bash -c 'source "$1/manul-env.sh"; manul_env_load "$2"' _ "$SCRIPT_DIR" "$INVALID" >/dev/null 2>&1
INVALID_RC=$?
set -e

[ "$INVALID_RC" -ne 0 ] && ok "Invalid operator environment fails closed" || fail "Invalid operator environment was accepted"

START_RUNTIME="$TMP/start-runtime"
FAKE_BIN="$TMP/fake-bin"
CRONTAB_FILE="$TMP/crontab"
mkdir -p "$START_RUNTIME" "$FAKE_BIN"

cat > "$START_RUNTIME/manul-daemon.sh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  start)
    echo "$$" > "$MANUL_FAKE_PID_FILE"
    exit 0
    ;;
  status)
    exit 0
    ;;
  stop)
    rm -f "$MANUL_FAKE_PID_FILE"
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
MOCK
chmod +x "$START_RUNTIME/manul-daemon.sh"

cat > "$START_RUNTIME/watchdog.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$START_RUNTIME/watchdog.sh"

cat > "$FAKE_BIN/setsid" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
chmod +x "$FAKE_BIN/setsid"

cat > "$FAKE_BIN/nohup" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
chmod +x "$FAKE_BIN/nohup"

cat > "$FAKE_BIN/crontab" <<'MOCK'
#!/usr/bin/env bash
set -e
case "$1" in
  -l)
    cat "$MANUL_FAKE_CRONTAB_FILE" 2>/dev/null || true
    ;;
  -)
    cat > "$MANUL_FAKE_CRONTAB_FILE"
    ;;
  *)
    exit 2
    ;;
esac
MOCK
chmod +x "$FAKE_BIN/crontab"

export MANUL_FAKE_PID_FILE="$START_RUNTIME/fake.pid"
export MANUL_FAKE_CRONTAB_FILE="$CRONTAB_FILE"

set +e
PATH="$FAKE_BIN:$PATH" MANUL_DIR="$START_RUNTIME" \
  "$SCRIPT_DIR/start-manul-automation.sh" start >/dev/null 2>&1
START_RC=$?
set -e

if [ "$START_RC" -eq 0 ] && [ -f "$START_RUNTIME/.enabled" ]; then
  ok "start-manul-automation.sh returns 0 on successful standalone start"
else
  fail "start-manul-automation.sh returned $START_RC or did not enable runtime"
fi

if grep -qF "$START_RUNTIME/watchdog.sh" "$CRONTAB_FILE" 2>/dev/null; then
  ok "Startup wrapper installs its runtime watchdog"
else
  fail "Startup wrapper did not install its runtime watchdog"
fi

set +e
PATH="$FAKE_BIN:$PATH" MANUL_DIR="$START_RUNTIME" \
  "$SCRIPT_DIR/start-manul-automation.sh" stop >/dev/null 2>&1
STOP_RC=$?
set -e

if [ "$STOP_RC" -eq 0 ] && [ ! -f "$START_RUNTIME/.enabled" ]; then
  ok "start-manul-automation.sh stop returns 0 and disables runtime"
else
  fail "start-manul-automation.sh stop returned $STOP_RC or left .enabled behind"
fi

if [ ! -s "$CRONTAB_FILE" ] || ! grep -qF "$START_RUNTIME/watchdog.sh" "$CRONTAB_FILE"; then
  ok "Startup wrapper removes its watchdog on stop"
else
  fail "Startup wrapper left its watchdog installed after stop"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
