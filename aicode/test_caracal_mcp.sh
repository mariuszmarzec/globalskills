#!/usr/bin/env bash
# test_caracal_mcp.sh — regression guards for mandatory Caracal MCP access.
# These checks are offline and never read or mutate the user's runtime config.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AICODE="$ROOT/aicode/aicode"
ACP_WRAPPER="$ROOT/aicode/opencode-acp-caracal.sh"
MANUL="$ROOT/skills/manul-github-bot"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
contains() {
  local file="$1" needle="$2" description="$3"
  grep -Fq -- "$needle" "$file" || fail "$description (missing in $file)"
  ok "$description"
}

bash -n "$AICODE" || fail "aicode shell syntax"
bash -n "$ACP_WRAPPER" || fail "OpenCode ACP wrapper shell syntax"
bash -n "$MANUL/opencode-adapter.sh" || fail "OpenCode adapter shell syntax"
bash -n "$MANUL/manul-env.sh" || fail "Manul env helper shell syntax"
ok "Caracal runtime scripts have valid shell syntax"

# The OpenCode CLI must use its native named-server config format. OpenClaw has
# a different mcp.servers schema and must not be copied into opencode.json.
contains "$AICODE" '"caracal-rag": {' "aicode registers Caracal in OpenCode"
contains "$AICODE" 'type: "remote"' "OpenCode config uses its native remote MCP type"
contains "$AICODE" 'url: "{env:CARACAL_MCP_URL}"' "OpenCode endpoint is injected via environment"
contains "$AICODE" 'Bearer {env:CARACAL_ACCESS_TOKEN}' "OpenCode bearer token is injected via environment"
contains "$AICODE" 'opencode mcp list' "aicode probes the real OpenCode MCP registry"
contains "$AICODE" 'OpenCode does not report caracal-rag as connected' "aicode fails closed if OpenCode MCP is disconnected"

# OpenClaw delegates to the OpenCode ACP harness. The launcher configures that
# specific target; it deliberately does not register a duplicate native MCP in OpenClaw.
contains "$AICODE" 'configure_openclaw_opencode_acp' "aicode configures the OpenCode ACP target"
contains "$AICODE" 'plugins.entries.acpx.enabled == true' "aicode requires the ACPX plugin to be enabled"
contains "$AICODE" 'command: "bash"' "ACPX starts the verified wrapper through bash"
contains "$AICODE" 'args: [$wrapper, "acp"]' "ACPX launches the OpenCode ACP wrapper"
contains "$AICODE" 'OpenClaw ACP OpenCode harness configured' "aicode verifies the ACP wrapper configuration"
contains "$ACP_WRAPPER" 'opencode mcp list' "ACP wrapper checks the effective OpenCode MCP registry"
contains "$ACP_WRAPPER" 'exec "$opencode_bin" acp "$@"' "ACP wrapper launches OpenCode over ACP only after the MCP check"
contains "$ACP_WRAPPER" 'load_caracal_token' "ACP wrapper refreshes Caracal credentials from the local secret store"

# Manul must preserve a current endpoint/token for unattended tasks and must
# make a task-local config plus a live MCP preflight before running OpenCode.
contains "$MANUL/manul-env.sh" 'CARACAL_MCP_URL' "Manul persists the Caracal endpoint"
contains "$MANUL/manul-env.sh" 'CARACAL_ACCESS_TOKEN' "Manul persists the Caracal token"
contains "$AICODE" 'manul_env_bootstrap "$MANUL_RUNTIME"' "aicode refreshes Manul's Caracal environment before repair/startup"
bootstrap_line="$(grep -nF 'manul_env_bootstrap "$MANUL_RUNTIME"' "$AICODE" | head -n 1 | cut -d: -f1)"
repair_line="$(grep -nF '"$MANUL_REPAIRER" >/dev/null' "$AICODE" | head -n 1 | cut -d: -f1)"
[ -n "$bootstrap_line" ] && [ -n "$repair_line" ] && [ "$bootstrap_line" -lt "$repair_line" ] || fail "Caracal environment refresh must happen before Manul repair"
ok "Manul's stored Caracal environment is refreshed before repair"
contains "$MANUL/opencode-adapter.sh" '"caracal-rag": {' "Manul injects Caracal into its task-local OpenCode config"
contains "$MANUL/opencode-adapter.sh" 'ProcessRunner.run --timeout 45' "Manul checks the live OpenCode MCP registry"
contains "$MANUL/opencode-adapter.sh" 'task was not started' "Manul refuses to start a task without a live Caracal connection"
contains "$MANUL/test_adapters.sh" 'test_opencode_caracal_mcp' "adapter tests cover connected and disconnected Caracal states"
contains "$MANUL/test_manul_environment.sh" 'Bootstrap refreshes Caracal URL/token' "environment tests cover Caracal endpoint/token refresh"

echo
echo "All Caracal MCP regression guards passed."
