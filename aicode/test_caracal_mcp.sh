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
contains "$AICODE" '"caracal-rag_*": true' "configured OpenCode agents can call Caracal tools"
contains "$AICODE" 'opencode mcp list' "aicode probes the real OpenCode MCP registry"
contains "$AICODE" 'OpenCode does not report caracal-rag as connected' "aicode fails closed if OpenCode MCP is disconnected"

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

# The jq merge program contains literal apostrophes in comments
# ("OpenCode's", "OpenClaw's"). They must be delivered to jq as a single
# program, never as an inline single-quoted argument: the apostrophes would
# terminate the shell quote early and jq would treat the comment words as
# filenames ("Could not open file MCP: No such file or directory").
contains "$AICODE" 'jq -s -f "$jq_program"' "aicode feeds the jq program from a file, not an inline quote"
contains "$AICODE" 'cat >"$jq_program" <<'"'"'JQ'"'"'' "aicode writes the jq program via a quoted heredoc"

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
printf '{"mcp":{"existing":true},"tools":{"foo":true},"agent":{"chat":{"tools":{"*":false}}}}' > "$merge_input"
if ! jq -s -f <(cat <<'JQ'
        (.[0] // {})
        # OpenCode's MCP schema is .mcp[server-name], unlike OpenClaw's
        # separate .mcp.servers schema.
        | .mcp = (
            (.mcp // {}) | if type == "object" then . else {} end
            | . + {
                "caracal-rag": {
                    type: "remote",
                    url: "{env:CARACAL_MCP_URL}",
                    oauth: false,
                    enabled: true,
                    headers: {Authorization: "Bearer {env:CARACAL_ACCESS_TOKEN}"}
                }
            }
          )
        | .tools = ((.tools // {}) | if type == "object" then . else {} end | . + {"caracal-rag_*": true})
        | .agent = (
            (.agent // {})
            | if type == "object" then
                with_entries(
                  if .key == "chat" then .
                  else .value.tools = ((.value.tools // {}) | if type == "object" then . else {} end | . + {"caracal-rag_*": true})
                  end
                )
              else {}
              end
          )
JQ
) "$merge_input" > "$merge_output" 2>/dev/null; then
    fail "jq merge with apostrophes in comments failed to produce output"
fi
jq -e '.mcp["caracal-rag"].url == "{env:CARACAL_MCP_URL}"' "$merge_output" >/dev/null || fail "merged config lost the caracal-rag url"
jq -e '.mcp["caracal-rag"].headers.Authorization == "Bearer {env:CARACAL_ACCESS_TOKEN}"' "$merge_output" >/dev/null || fail "merged config lost the bearer header"
jq -e '.mcp.existing == true' "$merge_output" >/dev/null || fail "merged config dropped unrelated .mcp entries"
jq -e '.tools.foo == true and .tools["caracal-rag_*"] == true' "$merge_output" >/dev/null || fail "merged config lost unrelated .tools entries"
jq -e '.agent.chat.tools."*" == false' "$merge_output" >/dev/null || fail "merged config dropped the chat agent"
ok "jq merge preserves existing config and registers caracal-rag"

# An inline single-quoted multi-line program with literal apostrophes must fail,
# which is exactly the defect this test guards against. The broken program is
# written to a file with literal apostrophes (not the '"'"' escape) so the
# shell quote is genuinely terminated mid-line.
broken_tmp="$tmp_dir/broken.json"
broken_prog="$tmp_dir/broken.jq"
printf '{"mcp":{}}' > "$broken_tmp"
printf '%s\n' \
    "        (.[0] // {})" \
    "        # OpenCode's MCP schema is .mcp[server-name], unlike OpenClaw's" \
    "        | .mcp = {}" \
    > "$broken_prog"
# Assemble the broken invocation the way the old aicode did: an inline
# single-quoted program followed by the input file argument.
broken_cmd="$tmp_dir/broken.sh"
{
    printf '#!/usr/bin/env bash\n'
    printf 'jq -s '
    # emit the literal single-quoted program, line by line
    while IFS= read -r line; do
        printf "'%s'" "$line"
    done < "$broken_prog"
    printf ' "%s"\n' "$broken_tmp"
} > "$broken_cmd"
chmod +x "$broken_cmd"
set +e
bash "$broken_cmd" > /dev/null 2>"$tmp_dir/broken.err"
broken_rc=$?
set -e
[ "$broken_rc" -ne 0 ] || fail "the broken inline-quote form unexpectedly succeeded"
grep -q "Could not open file" "$tmp_dir/broken.err" || grep -q "no matches found" "$tmp_dir/broken.err" || fail "the broken inline-quote form produced an unexpected error"
ok "the original inline single-quote defect is reproduced by this test"

echo
echo "All Caracal MCP regression guards passed."
