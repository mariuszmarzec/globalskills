#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=aicode/chroma-lifecycle.sh
. "$TEST_DIR/chroma-lifecycle.sh"

TEST_ROOT=""
MOCK_HOST="127.0.0.1"
MOCK_PORT="3400"
MOCK_SSL="false"
MOCK_READY="false"
MOCK_PORT_BUSY="false"
MOCK_START_MODE="healthy"
MOCK_START_COUNT=0
MOCK_MATCHED_PID=""
export CARACAL_CHROMA_READY_ATTEMPTS=2

cleanup() {
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
        rm -rf -- "$TEST_ROOT"
    fi
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    [[ "$expected" == "$actual" ]] || fail "$message (expected '$expected', got '$actual')"
}

reset_case() {
    cleanup
    TEST_ROOT="$(mktemp -d)"
    TEST_HOME="$TEST_ROOT/.caracal"
    mkdir -p "$TEST_HOME/venv/bin" "$TEST_HOME/config" "$TEST_HOME/chroma-data"
    : > "$TEST_HOME/config/sources.yaml"
    : > "$TEST_HOME/venv/bin/python"
    : > "$TEST_HOME/venv/bin/chroma"
    chmod +x "$TEST_HOME/venv/bin/python" "$TEST_HOME/venv/bin/chroma"
    MOCK_HOST="127.0.0.1"
    MOCK_PORT="3400"
    MOCK_SSL="false"
    MOCK_READY="false"
    MOCK_PORT_BUSY="false"
    MOCK_START_MODE="healthy"
    MOCK_START_COUNT=0
    MOCK_MATCHED_PID=""
}

# Replace external integrations with deterministic test doubles.
chroma_read_settings() {
    printf '%s\n' "$MOCK_HOST" "$MOCK_PORT" "$MOCK_SSL"
}

chroma_http_ready() {
    [[ "$MOCK_READY" == "true" ]]
}

chroma_pid_matches() {
    [[ -n "$MOCK_MATCHED_PID" && "$1" == "$MOCK_MATCHED_PID" ]]
}

chroma_port_listening() {
    [[ "$MOCK_PORT_BUSY" == "true" ]]
}

chroma_start_process() {
    local pid_file="$6"
    MOCK_START_COUNT=$((MOCK_START_COUNT + 1))
    MOCK_MATCHED_PID="$$"
    printf '%s\n' "$MOCK_MATCHED_PID" > "$pid_file"
    if [[ "$MOCK_START_MODE" == "healthy" ]]; then
        MOCK_READY="true"
    fi
    return 0
}

sleep() { :; }

# Healthy local instance is reused without launching a duplicate.
reset_case
MOCK_READY="true"
ensure_chroma_server "$TEST_HOME" || fail "healthy Chroma should be reused"
assert_eq "0" "$MOCK_START_COUNT" "healthy instance must not be relaunched"

# First startup uses the existing configured data directory and writes a PID file.
reset_case
ensure_chroma_server "$TEST_HOME" || fail "first local startup should become healthy"
assert_eq "1" "$MOCK_START_COUNT" "first startup should launch exactly once"
[[ -f "$TEST_HOME/run/chroma.pid" ]] || fail "startup must persist its PID"

# Stale PID state is removed safely before launching a replacement process.
reset_case
mkdir -p "$TEST_HOME/run"
printf '99999999\n' > "$TEST_HOME/run/chroma.pid"
ensure_chroma_server "$TEST_HOME" || fail "stale PID should not block startup"
assert_eq "1" "$MOCK_START_COUNT" "stale PID should cause one replacement start"
assert_eq "$$" "$(cat "$TEST_HOME/run/chroma.pid")" "replacement PID should be recorded"

# Remote Chroma is external and must never cause a local server launch.
reset_case
MOCK_HOST="chroma.example.net"
ensure_chroma_server "$TEST_HOME" || fail "remote configuration should be left externally managed"
assert_eq "0" "$MOCK_START_COUNT" "remote endpoint must not start a local Chroma"

# TLS-enabled Chroma is also externally managed by this launcher.
reset_case
MOCK_SSL="true"
ensure_chroma_server "$TEST_HOME" || fail "TLS configuration should be left externally managed"
assert_eq "0" "$MOCK_START_COUNT" "TLS endpoint must not start a plain HTTP server"

# An occupied port with no healthy Chroma endpoint must not be overwritten.
reset_case
MOCK_PORT_BUSY="true"
if ensure_chroma_server "$TEST_HOME"; then
    fail "unhealthy occupied port must fail safely"
fi
assert_eq "0" "$MOCK_START_COUNT" "port conflict must not launch a process"

# Failed readiness is reported and must not be mistaken for a successful startup.
reset_case
MOCK_START_MODE="unhealthy"
if ensure_chroma_server "$TEST_HOME"; then
    fail "unhealthy new process must not be reported as ready"
fi
assert_eq "1" "$MOCK_START_COUNT" "failed readiness should have attempted one start"

# Never create a new empty database when the existing vector directory is missing.
reset_case
rmdir "$TEST_HOME/chroma-data"
if ensure_chroma_server "$TEST_HOME"; then
    fail "missing data directory must fail safely"
fi
assert_eq "0" "$MOCK_START_COUNT" "missing existing data must prevent startup"

echo "PASS: Chroma lifecycle tests"
