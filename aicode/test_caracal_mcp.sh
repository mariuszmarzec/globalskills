#!/usr/bin/env bash
# test_caracal_mcp.sh — regression guards for mandatory Caracal MCP access.
# These checks are offline and never read or mutate the user's runtime config.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AICODE="$ROOT/aicode/aicode"
MANUL="$ROOT/skills/manul-github-bot"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }
contains() {
  local file="$1" needle="$2" description="$3"
  grep -Fq -- "$needle" "$file" || fail "$description (missing in $file)"
  ok "$description"
}

bash -n "$AICODE" || fail "aicode shell syntax"
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

# Native OpenClaw MCP config and policy access must be handled separately.
contains "$AICODE" 'mcp: {' "aicode patches native OpenClaw MCP config"
contains "$AICODE" 'transport: "streamable-http"' "OpenClaw uses streamable HTTP transport"
contains "$AICODE" 'headers: {Authorization: "Bearer ${CARACAL_ACCESS_TOKEN}"}' "OpenClaw uses the environment-backed bearer token"
contains "$AICODE" 'bundle-mcp' "OpenClaw MCP tools are included in tool-policy configuration"
contains "$AICODE" 'openclaw mcp doctor caracal-rag --probe' "aicode probes the live OpenClaw Caracal connection"
contains "$AICODE" 'explicit tool-deny rule blocking MCP tools' "aicode refuses to bypass explicit MCP denies"
contains "$AICODE" 'No agent runtime will start' "aicode fails closed when Caracal is unavailable"

# Manul must preserve a current endpoint/token for unattended tasks and must
# make a task-local config plus a live MCP preflight before running OpenCode.
contains "$MANUL/manul-env.sh" 'CARACAL_MCP_URL' "Manul persists the Caracal endpoint"
contains "$MANUL/manul-env.sh" 'CARACAL_ACCESS_TOKEN' "Manul persists the Caracal token"
contains "$MANUL/opencode-adapter.sh" '"caracal-rag": {' "Manul injects Caracal into its task-local OpenCode config"
contains "$MANUL/opencode-adapter.sh" 'opencode" mcp list' "Manul checks the live OpenCode MCP registry"
contains "$MANUL/opencode-adapter.sh" 'task was not started' "Manul refuses to start a task without a live Caracal connection"
contains "$MANUL/test_adapters.sh" 'test_opencode_caracal_mcp' "adapter tests cover connected and disconnected Caracal states"
contains "$MANUL/test_manul_environment.sh" 'Bootstrap refreshes Caracal URL/token' "environment tests cover Caracal endpoint/token refresh"

echo
echo "All Caracal MCP regression guards passed."
