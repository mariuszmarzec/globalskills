#!/usr/bin/env bash
# test_caracal_mcp.sh — regression guards for mandatory Caracal MCP access.
# These checks are offline and never read or mutate the user's runtime config.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AICODE="$ROOT/aicode/aicode"
ACP_WRAPPER="$ROOT/aicode/opencode-acp-caracal.sh"
MANUL="${MANUL_CANONICAL_DIR:-$HOME/.manul-repo/skills/manul-github-bot}"

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

# Ollama startup must wait for the HTTP API, not just the process or a fixed sleep.
contains "$AICODE" 'OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"' "aicode supports the configured Ollama API base URL"
contains "$AICODE" 'ollama_http_ready' "aicode probes Ollama's actual HTTP readiness"
contains "$AICODE" '/api/tags' "aicode waits for Ollama's HTTP API endpoint"
contains "$AICODE" 'Waiting for Ollama API' "aicode reports waiting for Ollama readiness"
contains "$AICODE" 'OLLAMA_READY_TIMEOUT' "Ollama readiness wait has a bounded timeout"
contains "$AICODE" 'Caracal embedding healthcheck not ready' "aicode retries transient Caracal embedding failures"
contains "$AICODE" 'check_attempts' "Caracal embedding retries have a bounded attempt count"

# OpenCode V2 uses mcp.servers and ordered MCP permission rules.
contains "$AICODE" 'opencode-config-v2.jq' "aicode uses the shared OpenCode V2 config merger"
contains "$ROOT/aicode/opencode-config-v2.jq" '"caracal-rag": {' "V2 merger registers Caracal"
contains "$ROOT/aicode/opencode-config-v2.jq" '"fiteo": {' "V2 merger registers Fiteo"
contains "$ROOT/aicode/opencode-config-v2.jq" 'servers:' "MCP entries are nested under mcp.servers"
contains "$ROOT/aicode/opencode-config-v2.jq" 'disabled: false' "V2 MCP uses disabled=false"
contains "$ROOT/aicode/opencode-config-v2.jq" 'action: "caracal_rag_*"' "Caracal tools receive V2 permission rules"
contains "$ROOT/aicode/opencode-config-v2.jq" 'action: "fiteo_*"' "Fiteo tools receive V2 permission rules"
contains "$ROOT/aicode/opencode-config-v2.jq" 'Bearer {env:CARACAL_ACCESS_TOKEN}' "Caracal bearer token is environment-backed"
contains "$ROOT/aicode/opencode-config-v2.jq" 'Bearer {env:FITEO_PAT}' "Fiteo bearer token is environment-backed"
contains "$AICODE" 'opencode mcp list' "aicode probes the live OpenCode MCP registry"
contains "$AICODE" 'OpenCode does not report caracal-rag as connected' "aicode fails closed if Caracal is disconnected"
contains "$ACP_WRAPPER" 'load_fiteo_mcp_environment' "ACP refreshes Fiteo credentials for long-lived Gateway sessions"
contains "$AICODE" 'mcp_list_rc=0' "aicode does not trust the aggregate MCP-list exit status when optional Fiteo is offline"
contains "$ROOT/README.md" 'FITEO_MANUL_PAT' "README documents the dedicated Manul Fiteo PAT"
contains "$ROOT/README.md" 'FITEO_MANUL_SHARE_USER_ID' "README documents the Manul share recipient"
contains "$ROOT/skills/fiteo-access/SKILL.md" 'Never substitute `FITEO_PAT`' "Fiteo access skill forbids operator PAT fallback"
contains "$ROOT/skills/fiteo-access/SKILL.md" 'FITEO_MANUL_PAT' "Fiteo access skill documents the dedicated Manul PAT"
contains "$ACP_WRAPPER" 'mcp_list_rc=0' "ACP does not fail just because optional Fiteo is offline"
contains "$MANUL/opencode-adapter.sh" "failure from an unrelated MCP must not block this task" "Manul treats Fiteo as an optional live dependency"

# The OpenClaw snapshot reader must be shared with its unit test, must use
# the file hash for config.patch concurrency, and must not blindly drop stdout's first line.
contains "$AICODE" '. "$OPENCLAW_SNAPSHOT_HELPER"' "aicode loads the tested OpenClaw snapshot helper"
contains "$AICODE" 'openclaw_config_snapshot_base_hash' "config.patch receives the validated file revision hash"
if grep -Fq 'tail -n +2' "$AICODE"; then
  fail "aicode must not blindly discard the first line of Gateway stdout"
fi
ok "OpenClaw snapshot integration uses validated parsing and the correct base hash"

# OpenClaw delegates to the OpenCode ACP harness. The launcher configures that
# specific target; it deliberately does not register a duplicate native MCP in OpenClaw.
contains "$AICODE" 'configure_openclaw_opencode_acp' "aicode configures the OpenCode ACP target"
contains "$AICODE" 'plugins.entries.acpx.enabled == true' "aicode requires the ACPX plugin to be enabled"
contains "$AICODE" '(.acp.enabled == true)' "aicode enables OpenClaw ACP when configuring the OpenCode harness"
contains "$AICODE" '.backend = "acpx"' "aicode selects the ACPX runtime backend"
contains "$AICODE" 'probeAgent: "opencode"' "ACPX startup healthcheck selects the OpenCode harness"
contains "$AICODE" 'command: "bash"' "ACPX starts the verified wrapper through bash"
contains "$AICODE" 'args: [$wrapper, "acp"]' "ACPX launches the OpenCode ACP wrapper"
contains "$AICODE" 'OpenClaw ACP OpenCode harness configured' "aicode verifies the ACP wrapper configuration"
contains "$ACP_WRAPPER" '"$opencode_bin" mcp list' "ACP wrapper checks the effective OpenCode MCP registry"
contains "$ACP_WRAPPER" 'exec "$opencode_bin" acp "$@"' "ACP wrapper launches OpenCode over ACP only after the MCP check"
contains "$ACP_WRAPPER" '. "$CARACAL_HOME/env.sh"' "ACP wrapper refreshes Caracal credentials from the Caracal provider"

# Manul must preserve a current endpoint/token for unattended tasks and must
# make a task-local config plus a live MCP preflight before running OpenCode.
contains "$MANUL/manul-env.sh" 'CARACAL_MCP_URL' "Manul persists the Caracal endpoint"
contains "$MANUL/manul-env.sh" 'CARACAL_ACCESS_TOKEN' "Manul persists the Caracal token"
contains "$MANUL/manul-env.sh" 'MANUL_HOST_SKILLS_DIR' "Manul persists the host project skills path for unattended tasks"
contains "$MANUL/todo-task-source-utils.sh" 'skills_dir="$HOME/.agents/skills"' "Manul reads mapped project skills from the canonical ~/.agents/skills directory"
contains "$AICODE" 'MANUL_HOST_SKILLS_DIR="${MANUL_HOST_SKILLS_DIR:-$HOME/.agents/skills}"' "aicode exposes the shared installed skills directory to standalone Manul"
contains "$AICODE" 'MANUL_CANONICAL_BRANCH="${MANUL_CANONICAL_BRANCH:-master}"' "aicode uses Manul default branch master"
contains "$AICODE" 'manul_env_bootstrap "$MANUL_RUNTIME"' "aicode refreshes Manul's Caracal environment before repair/startup"
bootstrap_line="$(grep -nF 'manul_env_bootstrap "$MANUL_RUNTIME"' "$AICODE" | head -n 1 | cut -d: -f1)"
repair_line="$(grep -nF '"$MANUL_REPAIRER" >/dev/null' "$AICODE" | head -n 1 | cut -d: -f1)"
[ -n "$bootstrap_line" ] && [ -n "$repair_line" ] && [ "$bootstrap_line" -lt "$repair_line" ] || fail "Caracal environment refresh must happen before Manul repair"
ok "Manul's stored Caracal environment is refreshed before repair"
if grep -Fq 'disabled:false' "$MANUL/opencode-adapter.sh"; then
  contains "$MANUL/opencode-adapter.sh" 'mcp.servers' "Manul injects V2 MCP servers into its task-local config"
  contains "$MANUL/opencode-adapter.sh" 'disabled:false' "Manul task MCP uses V2 disabled semantics"
else
  contains "$MANUL/opencode-adapter.sh" '"caracal-rag": {' "legacy Manul injects Caracal into task-local OpenCode config"
  contains "$MANUL/opencode-adapter.sh" '"fiteo": {' "legacy Manul injects Fiteo into task-local OpenCode config"
fi
# Keep the integration test compatible while the standalone Manul PR is in review.
# Once the dedicated-token branch is merged, assert the stricter token boundary.
if grep -Fq 'Bearer {env:FITEO_MANUL_PAT}' "$MANUL/opencode-adapter.sh"; then
  contains "$MANUL/opencode-adapter.sh" 'Bearer {env:FITEO_MANUL_PAT}' "Manul task config resolves its dedicated Fiteo PAT"
  contains "$MANUL/manul-env.sh" 'FITEO_MANUL_PAT' "Manul persists its dedicated Fiteo PAT for unattended tasks"
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?FITEO_PAT=' "$MANUL/manul-env.sh"; then
    fail "Manul runtime must not persist the operator FITEO_PAT"
  fi
else
  contains "$MANUL/opencode-adapter.sh" 'Bearer {env:FITEO_PAT}' "legacy Manul task config resolves its Fiteo PAT"
  contains "$MANUL/manul-env.sh" 'FITEO_PAT' "legacy Manul persists the Fiteo PAT for unattended tasks"
fi
contains "$MANUL/manul-env.sh" 'FITEO_BASE_URL' "Manul persists the Fiteo backend base URL"
contains "$MANUL/opencode-adapter.sh" '_FITEO_RUNTIME_ENV_FILE' "Manul refreshes Fiteo credentials from disk for each task"
if grep -Fq '.mcp.servers["todo-local"]' "$MANUL/opencode-adapter.sh"; then
  contains "$MANUL/opencode-adapter.sh" '.mcp.servers["todo-local"]' "Manul injects Todo local MCP into the task-local V2 config when available"
  contains "$MANUL/opencode-adapter.sh" 'env.TODO_LOCAL_MCP_AVAILABLE' "Manul only injects Todo MCP after endpoint discovery"
else
  contains "$MANUL/opencode-adapter.sh" '"todo-local": {' "legacy Manul injects Todo local MCP into the task-local OpenCode config when available"
fi
contains "$MANUL/opencode-adapter.sh" 'todo_local_mcp_preflight' "Manul verifies Todo local MCP before starting an enabled task"
contains "$MANUL/opencode-adapter.sh" 'unset TODO_LOCAL_MCP_TOKEN' "Manul never loads or forwards the legacy Todo token"
contains "$MANUL/opencode-adapter.sh" 'ProcessRunner.run --timeout 45' "Manul checks the live OpenCode MCP registry"
contains "$MANUL/opencode-adapter.sh" 'task was not started' "Manul refuses to start a task without a live Caracal connection"
contains "$MANUL/test_adapters.sh" 'test_opencode_caracal_mcp' "adapter tests cover connected and disconnected Caracal states"
contains "$MANUL/test_manul_environment.sh" 'Bootstrap refreshes Caracal URL/token' "environment tests cover Caracal endpoint/token refresh"

# The shared jq transformer is stored as a tracked source file, so comments
# with apostrophes are safe and the launcher executes that exact file.
contains "$AICODE" 'jq -s -f "$jq_program"' "aicode feeds the shared V2 jq program from a file"
contains "$ROOT/aicode/opencode-config-v2.jq" "OpenCode's" "the shared V2 jq program retains readable comments"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# The launcher must follow the exact same runtime precedence as Manul:
# automation.agentRuntime=opencode means no OpenClaw Gateway/ACPX setup,
# while roleRuntime alone must not override the automatic agent runtime.
runtime_config_dir="$tmp_dir/manul-runtime"
mkdir -p "$runtime_config_dir"
printf '%s\n' '{"automation":{"agentRuntime":"opencode","roleRuntime":"openclaw"}}' > "$runtime_config_dir/config.json"
selected_runtime="$(MANUL_DIR="$runtime_config_dir" AGENT_RUNTIME= MANUL_AGENT_RUNTIME= bash -c 'source "$1"; printf "%s" "$AGENT_RUNTIME"' _ "$MANUL/manul-paths.sh")"
[ "$selected_runtime" = "opencode" ] || fail "runtime selection ignored automation.agentRuntime=opencode (got $selected_runtime)"
ok "Manul config selects OpenCode as the automatic agent runtime"

selected_runtime="$(MANUL_DIR="$runtime_config_dir" AGENT_RUNTIME=openclaw MANUL_AGENT_RUNTIME= bash -c 'source "$1"; printf "%s" "$AGENT_RUNTIME"' _ "$MANUL/manul-paths.sh")"
[ "$selected_runtime" = "openclaw" ] || fail "explicit AGENT_RUNTIME environment override was ignored (got $selected_runtime)"
ok "explicit runtime environment override takes precedence over Manul config"

runtime_role_only_dir="$tmp_dir/manul-role-only"
mkdir -p "$runtime_role_only_dir"
printf '%s\n' '{"automation":{"roleRuntime":"opencode"}}' > "$runtime_role_only_dir/config.json"
selected_runtime="$(MANUL_DIR="$runtime_role_only_dir" AGENT_RUNTIME= MANUL_AGENT_RUNTIME= bash -c 'source "$1"; printf "%s" "$AGENT_RUNTIME"' _ "$MANUL/manul-paths.sh")"
[ "$selected_runtime" = "openclaw" ] || fail "roleRuntime=opencode incorrectly changed the automatic runtime (got $selected_runtime)"
ok "roleRuntime=opencode alone retains Manul's default automatic OpenClaw runtime"

# The final Gateway startup and ACPX configuration call must be guarded by
# AGENT_RUNTIME=openclaw. The earlier matching guard loads the snapshot helper;
# this later guard must enclose the actual Gateway launch/configuration calls.
runtime_gate_line="$(grep -nF 'if [ "$AGENT_RUNTIME" = "openclaw" ]; then' "$AICODE" | sed -n '2p' | cut -d: -f1)"
gateway_start_line="$(grep -nF 'nohup openclaw gateway' "$AICODE" | cut -d: -f1)"
acpx_call_line="$(grep -nF 'if ! configure_openclaw_opencode_acp; then' "$AICODE" | cut -d: -f1)"
[ -n "$runtime_gate_line" ] && [ -n "$gateway_start_line" ] && [ -n "$acpx_call_line" ] &&
  [ "$runtime_gate_line" -lt "$gateway_start_line" ] && [ "$gateway_start_line" -lt "$acpx_call_line" ] ||
  fail "OpenClaw Gateway/ACPX operations are not gated by the selected agent runtime"
ok "OpenClaw Gateway and ACPX are only initialized for OpenClaw agentRuntime"
merge_input="$tmp_dir/input.json"
merge_output="$tmp_dir/output.json"
printf '%s\n' '{"mcp":{"timeout":{"catalog":5000},"legacy":{"type":"local","command":["node","server.js"],"enabled":true,"timeout":12000},"legacy-disabled":{"type":"local","command":["node","disabled.js"],"enabled":false},"servers":{"native-existing":{"type":"remote","url":"https://native.example/mcp","disabled":true}}},"experimental":{"mcp_timeout":15000},"tools":{"foo":true},"agent":{"coder":{"tools":{"*":true}},"chat":{"tools":{"*":false}}}}' > "$merge_input"
TODO_LOCAL_MCP_AVAILABLE=1 jq -s -f "$ROOT/aicode/opencode-config-v2.jq" "$merge_input" > "$merge_output" || fail "V2 MCP merge failed"
jq -e '.mcp.servers["caracal-rag"].url == "{env:CARACAL_MCP_URL}" and .mcp.servers["caracal-rag"].disabled == false' "$merge_output" >/dev/null || fail "Caracal V2 server missing or disabled"
jq -e '.mcp.servers.fiteo.url == "{env:FITEO_BASE_URL}/mcp" and .mcp.servers.fiteo.headers.Authorization == "Bearer {env:FITEO_PAT}" and .mcp.servers.fiteo.disabled == false' "$merge_output" >/dev/null || fail "Fiteo V2 server missing or disabled"
jq -e '.mcp.servers.legacy.disabled == false and .mcp.servers.legacy.timeout.catalog == 12000 and .mcp.servers.legacy.timeout.execution == 12000' "$merge_output" >/dev/null || fail "legacy MCP entry was not migrated"
jq -e '(.mcp | has("legacy") | not) and (.mcp | has("legacy-disabled") | not)' "$merge_output" >/dev/null || fail "legacy MCP entries remain at the V1 mcp root"
jq -e '.mcp.servers["legacy-disabled"].disabled == true and (.mcp.servers["legacy-disabled"] | has("enabled") | not)' "$merge_output" >/dev/null || fail "legacy disabled MCP entry was accidentally enabled"
jq -e '.mcp.timeout.catalog == 5000 and .mcp.timeout.execution == 15000 and (.experimental | has("mcp_timeout") | not)' "$merge_output" >/dev/null || fail "MCP-wide settings/legacy default timeout were not preserved"
jq -e '.mcp.servers["native-existing"].disabled == true' "$merge_output" >/dev/null || fail "native MCP server was not preserved"
jq -e 'any(.permissions[]; .action == "caracal_rag_*" and .resource == "*" and .effect == "allow") and any(.permissions[]; .action == "fiteo_*" and .resource == "*" and .effect == "allow") and any(.permissions[]; .action == "todo_local_*" and .resource == "*" and .effect == "allow")' "$merge_output" >/dev/null || fail "V2 MCP permissions are incomplete"
jq -e '.mcp.servers["todo-local"].disabled == false' "$merge_output" >/dev/null || fail "enabled Todo local MCP server missing"
jq -e '.mcp.servers["todo-local"] | has("headers") | not' "$merge_output" >/dev/null || fail "Todo local MCP unexpectedly has authentication headers"
jq -e '.tools.foo == true and .tools["caracal-rag_*"] == true and .tools["fiteo_*"] == true' "$merge_output" >/dev/null || fail "unrelated tool config was lost"
jq -e '.agent.coder.tools["fiteo_*"] == true and .agent.chat.tools."*" == false' "$merge_output" >/dev/null || fail "legacy agent tool settings or chat restriction were lost"
TODO_LOCAL_MCP_AVAILABLE=0 jq -s -f "$ROOT/aicode/opencode-config-v2.jq" "$merge_output" > "$tmp_dir/output-no-todo.json" || fail "V2 merge with Todo disabled failed"
jq -e '.mcp.servers | has("todo-local") | not' "$tmp_dir/output-no-todo.json" >/dev/null || fail "optional Todo MCP was not removed"
jq -e 'any(.permissions[]; .action == "todo_local_*") | not' "$tmp_dir/output-no-todo.json" >/dev/null || fail "optional Todo permissions were not removed"
ok "shared jq converter migrates legacy MCP entries and preserves native config"
contains "$AICODE" 'jq -s -f "$jq_program" "$config_input"' "aicode executes the tested V2 jq file"
echo "All Caracal MCP regression guards passed."


# Todo Desktop runs in Windows; OpenCode receives only the authenticated WSL loopback bridge.
contains "$AICODE" 'unset TODO_LOCAL_MCP_TOKEN' "aicode prevents legacy Todo credentials from reaching OpenCode"
if grep -Fq 'todo-mcp.env' "$AICODE"; then
  fail "aicode must not load a Todo token environment file"
else
  ok "aicode does not load a Todo token environment file"
fi
contains "$AICODE" 'ensure_todo_mcp_bridge' "aicode starts the optional Todo bridge before OpenCode"
contains "$AICODE" 'todo_local_mcp_probe_status' "aicode uses the shared MCP handshake probe"
contains "$ROOT/aicode/opencode-config-v2.jq" 'url: "{env:TODO_LOCAL_MCP_URL}"' "OpenCode uses the platform-resolved Todo MCP endpoint"
contains "$AICODE" 'http://127.0.0.1:8765/mcp' "aicode probes Todo Desktop's native loopback endpoint first"
contains "$AICODE" 'todo_local_mcp_is_wsl' "aicode only starts the Windows bridge inside WSL"
contains "$MANUL/todo-local-mcp-url.sh" 'todo_local_mcp_resolve_url' "aicode and Manul share Todo endpoint discovery"
if grep -Fq 'TODO_LOCAL_MCP_TOKEN' "$ROOT/aicode/opencode-config-v2.jq"; then
  fail "OpenCode Todo config must not contain a token reference"
else
  ok "OpenCode Todo config contains no token reference"
fi
contains "$ROOT/aicode/todo-mcp-bridge.ps1" 'channel.BeginConnect(relay, relayPort' "Windows bridge initiates outbound connections to the WSL relay"
contains "$ROOT/aicode/todo-mcp-bridge.ps1" 'upstream.Connect(IPAddress.Loopback, 8765)' "Windows bridge still forwards to Todo Desktop's loopback MCP endpoint"
contains "$ROOT/aicode/todo-mcp-bridge.ps1" 'Only HTTP GET/POST/DELETE requests to /mcp are allowed.' "Windows bridge restricts forwarded HTTP methods and MCP path"
contains "$ROOT/aicode/todo-mcp-local-proxy.py" 'allowed_reverse_client' "WSL relay restricts reverse channels to the Windows gateway address"
contains "$AICODE" '--reverse-listen-host' "aicode binds the reverse listener to the current WSL address"
contains "$AICODE" 'Starting the WSL-side Todo MCP reverse relay' "aicode starts the WSL listener before the Windows connector"

python3 "$ROOT/aicode/test_todo_mcp_bridge.py"
