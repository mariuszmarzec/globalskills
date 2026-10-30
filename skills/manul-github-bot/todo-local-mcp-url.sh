#!/usr/bin/env bash
# Shared endpoint discovery for Todo Desktop's loopback-only MCP server.
#
# Native macOS/Linux/Windows clients use Todo's direct loopback endpoint.
# WSL first tries direct loopback (for mirrored/forwarded configurations), then
# the narrowly-scoped WSL relay maintained by aicode.

todo_local_mcp_is_wsl() {
  case "${TODO_LOCAL_MCP_PLATFORM_OVERRIDE:-}" in
    wsl) return 0 ;;
    native) return 1 ;;
  esac

  if [ -n "${WSL_INTEROP:-}" ] || [ -n "${WSL_DISTRO_NAME:-}" ]; then
    return 0
  fi

  if [ -r /proc/sys/kernel/osrelease ] &&
     grep -Eqi '(microsoft|wsl)' /proc/sys/kernel/osrelease; then
    return 0
  fi
  if [ -r /proc/version ] && grep -Eqi '(microsoft|wsl)' /proc/version; then
    return 0
  fi
  return 1
}

todo_local_mcp_url_is_supported() {
  case "${1:-}" in
    http://127.0.0.1:8765/mcp|http://127.0.0.1:8766/mcp) return 0 ;;
    *) return 1 ;;
  esac
}

todo_local_mcp_probe_status() {
  local url="$1"
  if ! command -v curl >/dev/null 2>&1; then
    printf '000'
    return 0
  fi
  curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 4 "$url" 2>/dev/null || printf '000'
}

# Prints the usable local endpoint only after an unauthenticated request is
# rejected with HTTP 401. An explicitly configured legacy relay URL is treated
# as a preference, not as a platform-independent default.
todo_local_mcp_resolve_url() {
  local preferred="${1:-${TODO_LOCAL_MCP_URL:-}}"
  local direct_url="http://127.0.0.1:8765/mcp"
  local bridge_url="http://127.0.0.1:8766/mcp"
  local status

  if [ -n "$preferred" ] && ! todo_local_mcp_url_is_supported "$preferred"; then
    echo "Todo local MCP URL must be one of the supported loopback endpoints." >&2
    return 2
  fi

  status="$(todo_local_mcp_probe_status "$direct_url")"
  if [ "$status" = "401" ]; then
    printf '%s' "$direct_url"
    return 0
  fi

  if todo_local_mcp_is_wsl; then
    status="$(todo_local_mcp_probe_status "$bridge_url")"
    if [ "$status" = "401" ]; then
      printf '%s' "$bridge_url"
      return 0
    fi
  fi

  # Backward compatibility for operators who explicitly configured the WSL
  # relay URL on a native host. Do not probe 8766 unless it was explicitly set.
  if [ "$preferred" = "$bridge_url" ] && ! todo_local_mcp_is_wsl; then
    status="$(todo_local_mcp_probe_status "$bridge_url")"
    if [ "$status" = "401" ]; then
      printf '%s' "$bridge_url"
      return 0
    fi
  fi

  return 1
}
