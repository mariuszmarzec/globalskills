#!/usr/bin/env bash
# Unit tests for OpenClaw config.get snapshot parsing. Uses a mocked CLI only.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/aicode/openclaw-config-snapshot.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
assert_equal() {
    local expected="$1" actual="$2" description="$3"
    [ "$actual" = "$expected" ] || fail "$description (expected '$expected', got '$actual')"
    ok "$description"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mock_bin="$tmp_dir/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/openclaw" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 5 ] &&
[ "$1" = "gateway" ] &&
[ "$2" = "call" ] &&
[ "$3" = "config.get" ] &&
[ "$4" = "--params" ] &&
[ "$5" = "{}" ] || exit 96

case "${OPENCLAW_MOCK_MODE:-prefix}" in
    prefix)
        printf 'Gateway call: config.get\n%s\n' "${OPENCLAW_MOCK_RESPONSE:-}"
        ;;
    raw)
        printf '%s\n' "${OPENCLAW_MOCK_RESPONSE:-}"
        ;;
    fail)
        echo "simulated Gateway CLI failure" >&2
        exit 17
        ;;
    *)
        echo "unknown mock mode" >&2
        exit 97
        ;;
esac
MOCK
chmod +x "$mock_bin/openclaw"
PATH="$mock_bin:$PATH"
export PATH

valid_json='{"config":{"plugins":{"entries":{"acpx":{"enabled":true}}},"acp":{"allowedAgents":["opencode"]}},"hash":"raw-file-hash","configRevisionHash":"resolved-config-hash","appliedConfigHash":"applied-runtime-hash"}'

# Prefix is stripped only when it is the known CLI advisory line; hash fields
# with different values prove baseHash is taken from .hash, not revision hashes.
export OPENCLAW_MOCK_MODE=prefix
export OPENCLAW_MOCK_RESPONSE="$valid_json"
snapshot="$(openclaw_config_get_snapshot)" || fail "prefixed valid snapshot was rejected"
printf '%s\n' "$snapshot" | jq -e '.config.plugins.entries.acpx.enabled == true' >/dev/null || fail "config was not preserved after prefix removal"
base_hash="$(printf '%s\n' "$snapshot" | openclaw_config_snapshot_base_hash)" || fail "base hash could not be extracted"
assert_equal "raw-file-hash" "$base_hash" "config.patch baseHash uses the raw file hash, not configRevisionHash/appliedConfigHash"
snapshot_config="$(printf '%s\n' "$snapshot" | openclaw_config_snapshot_config)" || fail "config object could not be extracted"
printf '%s\n' "$snapshot_config" | jq -e '.acp.allowedAgents == ["opencode"]' >/dev/null || fail "config extractor returned incorrect content"
ok "known Gateway advisory prefix is removed and config/hash are preserved"

# Raw JSON output remains valid if a later CLI version drops the advisory line.
export OPENCLAW_MOCK_MODE=raw
snapshot="$(openclaw_config_get_snapshot)" || fail "raw valid JSON snapshot was rejected"
printf '%s\n' "$snapshot" | jq -e '.hash == "raw-file-hash"' >/dev/null || fail "raw JSON was damaged"
ok "valid JSON without an advisory prefix is accepted unchanged"

# The resolved/applied hashes must never silently substitute for config.patch's
# baseHash, even if both alternatives are present.
export OPENCLAW_MOCK_RESPONSE='{"config":{},"configRevisionHash":"resolved-only","appliedConfigHash":"applied-only"}'
if openclaw_config_get_snapshot >/dev/null; then
    fail "snapshot without .hash was accepted"
fi
ok "snapshot without .hash is rejected even when other hashes exist"

export OPENCLAW_MOCK_RESPONSE='{"hash":"raw-file-hash","config":[]}'
if openclaw_config_get_snapshot >/dev/null; then
    fail "snapshot with a non-object config was accepted"
fi
ok "snapshot with missing or non-object config is rejected"

export OPENCLAW_MOCK_RESPONSE='not JSON'
if openclaw_config_get_snapshot >/dev/null; then
    fail "malformed JSON was accepted"
fi
ok "malformed JSON is rejected"

export OPENCLAW_MOCK_RESPONSE=$'Gateway call: other.method\n{"config":{},"hash":"raw-file-hash"}'
if openclaw_config_get_snapshot >/dev/null; then
    fail "unknown advisory prefix was accepted"
fi
ok "unexpected advisory output is rejected instead of being blindly stripped"

export OPENCLAW_MOCK_RESPONSE='{"config":{},"hash":"one"} {"config":{},"hash":"two"}'
if openclaw_config_get_snapshot >/dev/null; then
    fail "multiple JSON values were accepted as one snapshot"
fi
ok "multiple JSON documents are rejected"

export OPENCLAW_MOCK_RESPONSE=''
if openclaw_config_get_snapshot >/dev/null; then
    fail "empty output was accepted"
fi
ok "empty output is rejected"

export OPENCLAW_MOCK_MODE=fail
if openclaw_config_get_snapshot >/dev/null; then
    fail "a failing OpenClaw CLI command was treated as a successful snapshot"
fi
ok "OpenClaw command failure is preserved and cannot be masked by a downstream command"

if printf '%s\n' '{"config":{},"configRevisionHash":"not-a-base-hash"}' | openclaw_config_snapshot_base_hash >/dev/null 2>&1; then
    fail "base hash extractor accepted a response without .hash"
fi
ok "base hash extractor fails closed when .hash is absent"

echo
echo "All OpenClaw snapshot tests passed."
