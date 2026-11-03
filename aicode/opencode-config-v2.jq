# OpenCode V2 config merge for globalskills/aicode.
# Move legacy V1 named MCP entries into mcp.servers and normalize fields whose
# spelling or meaning changed; preserve MCP-wide settings and prefer native V2.
def migrate_mcp_server:
  . as $server
  | (if ($server.timeout | type) == "number" then
       .timeout = {catalog: $server.timeout, execution: $server.timeout}
     else . end)
  | if ($server | has("enabled")) then
      .disabled = ($server.enabled | not) | del(.enabled)
    else . end
  | if has("clientId") then .client_id = .clientId | del(.clientId) else . end
  | if has("clientSecret") then .client_secret = .clientSecret | del(.clientSecret) else . end
  | if has("callbackPort") then .callback_port = .callbackPort | del(.callbackPort) else . end
  | if has("redirectUri") then .redirect_uri = .redirectUri | del(.redirectUri) else . end;

(.[0] // {}) as $root
| ($root.mcp // {} | if type == "object" then . else {} end) as $mcp
| ($mcp.servers // {} | if type == "object" then . else {} end) as $nativeServers
| ($mcp | del(.servers, .timeout)) as $legacyServers
| $root
| .mcp = (
    (if ($mcp.timeout | type) == "number" then
       {timeout: {catalog: $mcp.timeout, execution: $mcp.timeout}}
     elif ($mcp.timeout | type) == "object" then
       {timeout: $mcp.timeout}
     else {} end)
    + {
        servers: (
          ($legacyServers + $nativeServers)
          | with_entries(.value |= migrate_mcp_server)
          + {
              "caracal-rag": {
                type: "remote",
                url: "{env:CARACAL_MCP_URL}",
                oauth: false,
                disabled: false,
                headers: {Authorization: "Bearer {env:CARACAL_ACCESS_TOKEN}"}
              },
              "fiteo": {
                type: "remote",
                url: "{env:FITEO_BASE_URL}/mcp",
                oauth: false,
                disabled: false,
                headers: {Authorization: "Bearer {env:FITEO_PAT}"}
              }
            }
        )
      }
  )
| if (($root.experimental.mcp_timeout // null) | type) == "number" then
    .mcp.timeout = (
      (.mcp.timeout // {} | if type == "object" then . else {} end)
      | . + {
          catalog: (.catalog // $root.experimental.mcp_timeout),
          execution: (.execution // $root.experimental.mcp_timeout)
        }
    )
    | .experimental |= del(.mcp_timeout)
  else .
  end
| .permissions = (
    ((.permissions // []) | if type == "array" then . else [] end)
    | reduce [
        {action: "caracal_rag_*", resource: "*", effect: "allow"},
        {action: "fiteo_*", resource: "*", effect: "allow"}
      ][] as $rule (
        .;
        map(select(.action != $rule.action or .resource != $rule.resource)) + [$rule]
      )
  )
| .tools = ((.tools // {}) | if type == "object" then . else {} end
    | . + {"caracal-rag_*": true, "fiteo_*": true})
| .agent = (
    (.agent // {})
    | if type == "object" then
        with_entries(
          if .key == "chat" then .
          else .value.tools = ((.value.tools // {}) | if type == "object" then . else {} end
            | . + {"caracal-rag_*": true, "fiteo_*": true})
          end
        )
      else {}
      end
  )
| if (env.TODO_LOCAL_MCP_AVAILABLE // "0") == "1" then
    .mcp.servers["todo-local"] = {
      type: "remote",
      url: "{env:TODO_LOCAL_MCP_URL}",
      oauth: false,
      disabled: false,
      headers: {Authorization: "Bearer {env:TODO_LOCAL_MCP_TOKEN}"}
    }
    | .permissions = (
        (.permissions // [])
        | map(select(.action != "todo_local_*" or .resource != "*"))
        + [{action: "todo_local_*", resource: "*", effect: "allow"}]
      )
    | .tools = ((.tools // {}) | if type == "object" then . else {} end
      | . + {"todo-local_*": true})
    | .agent = (
        (.agent // {})
        | if type == "object" then
            with_entries(
              if .key == "chat" then .
              else .value.tools = ((.value.tools // {}) | if type == "object" then . else {} end
                | . + {"todo-local_*": true})
              end
            )
          else {}
          end
      )
  else
    .mcp.servers |= del(."todo-local")
    | .permissions = ((.permissions // []) | map(select(.action != "todo_local_*" or .resource != "*")))
    | .tools = ((.tools // {}) | if type == "object" then . else {} end | del(."todo-local_*"))
    | .agent = (
        (.agent // {})
        | if type == "object" then
            with_entries(
              if .key == "chat" then .
              else .value.tools = ((.value.tools // {}) | if type == "object" then . else {} end
                | del(."todo-local_*"))
              end
            )
          else {}
          end
      )
  end
