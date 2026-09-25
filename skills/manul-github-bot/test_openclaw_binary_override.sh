#!/usr/bin/env bash
# test_openclaw_binary_override.sh — verify OpenClawAdapter honors OPENCLAW_BIN.
#
# Uses an isolated fake executable that is deliberately outside PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/custom-openclaw" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'TASK_DONE custom-binary'
exit 0
MOCK
chmod +x "$tmp/bin/custom-openclaw"
printf '%s\n' 'Do the task' >"$tmp/prompt"
: >"$tmp/stdout"
: >"$tmp/stderr"

set +e
out="$(PATH="/usr/bin:/bin" \
  OPENCLAW_BIN="$tmp/bin/custom-openclaw" \
  AGENT_RUNTIME=openclaw \
  MANUL_DIR="$tmp/runtime" \
  bash "$SCRIPT_DIR/openclaw-adapter.sh" \
    --task-id oc-custom \
    --prompt "$tmp/prompt" \
    --workspace "$tmp" \
    --attempt 1 \
    --timeout 30 \
    --session-id "" \
    --stdout-file "$tmp/stdout" \
    --stderr-file "$tmp/stderr" 2>/dev/null)"
rc=$?
set -e

status="$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null || true)"

if [ "$rc" -eq 0 ] && [ "$status" = "COMPLETED" ]; then
  echo "PASS: OpenClawAdapter honors explicit OPENCLAW_BIN outside PATH"
else
  echo "FAIL: custom OpenClaw binary was not executed (rc=$rc status=$status output=$out)"
  exit 1
fi

if grep -qx 'TASK_DONE custom-binary' "$tmp/stdout"; then
  echo "PASS: explicit custom OpenClaw binary produced the expected task output"
else
  echo "FAIL: expected TASK_DONE marker was not produced"
  exit 1
fi

echo "All OpenClaw binary override tests passed."
