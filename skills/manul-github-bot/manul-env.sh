#!/usr/bin/env bash
# manul-env.sh — Load and bootstrap Manul operator environment.
#
# The daemon and watchdog can run from cron/systemd without a login shell, so
# provider-specific environment must not rely on ~/.zshrc.
#
# Runtime-owned environment file:
#   ~/.manul/.env
#
# The bootstrap operation preserves existing operator settings, adds supported
# provider settings, and refreshes Caracal endpoint credentials when the launcher
# supplies current values. It never copies arbitrary environment variables.

manul_env_file() {
  local runtime_dir="${1:-${MANUL_DIR:-$HOME/.manul}}"
  printf '%s/.env' "$runtime_dir"
}

manul_env_load() {
  local runtime_dir="${1:-${MANUL_DIR:-$HOME/.manul}}"
  local env_file
  env_file="$(manul_env_file "$runtime_dir")"

  [ -f "$env_file" ] || return 0

  if ! bash -n "$env_file" >/dev/null 2>&1; then
    echo "ERROR: invalid shell syntax in Manul environment file: $env_file" >&2
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
}

manul_env_bootstrap() {
  local runtime_dir="${1:?runtime directory required}"
  local env_file
  env_file="$(manul_env_file "$runtime_dir")"

  mkdir -p "$runtime_dir" || return 1

  if [ -e "$env_file" ] && [ ! -f "$env_file" ]; then
    echo "ERROR: Manul environment path exists but is not a regular file: $env_file" >&2
    return 1
  fi

  if [ ! -f "$env_file" ]; then
    if ! cat > "$env_file" <<'EOF'
# Manul operator environment.
#
# This file is loaded by unattended Manul processes (daemon/watchdog).
# Keep provider-specific paths here when they are not available from cron,
# for example OPENCLAW_STATE_DIR, OPENCLAW_CONFIG_PATH, OPENCODE_CONFIG,
# and OPENCODE_BIN. Only explicitly supported variables are persisted.
#
# The installer only copies a small allowlist of provider variables from the
# current process environment. Existing entries are always preserved.
EOF
    then
      return 1
    fi
    chmod 600 "$env_file" || return 1
  fi

  local variable value refreshed_file
  for variable in \
    OPENCLAW_STATE_DIR \
    OPENCLAW_CONFIG_PATH \
    OPENCLAW_HOME \
    OPENCLAW_GATEWAY_PORT \
    OPENCLAW_BIN \
    OPENCODE_BIN \
    OPENCODE_CONFIG \
    CARACAL_MCP_URL \
    CARACAL_ACCESS_TOKEN \
    MANUL_JIRA_USER \
    MANUL_JIRA_PASSWORD; do
    value="${!variable:-}"
    [ -n "$value" ] || continue

    # Caracal's URL/token can change between launcher runs. Refresh those two
    # allowlisted values so each isolated task runner loads the current endpoint
    # and credential from ~/.manul/.env, even when the long-lived daemon predates
    # the latest launcher invocation. Preserve every unrelated operator setting.
    case "$variable" in
      CARACAL_MCP_URL|CARACAL_ACCESS_TOKEN)
        refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
        if ! awk -v name="$variable" '$0 !~ "^[[:space:]]*(export[[:space:]]+)?" name "="' "$env_file" > "$refreshed_file"; then
          rm -f -- "$refreshed_file"
          return 1
        fi
        printf '%s=%q\n' "$variable" "$value" >> "$refreshed_file"
        chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
        mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
        echo "  Refreshed $variable for unattended Manul processes" >&2
        ;;
      *)
        if ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${variable}=" "$env_file"; then
          printf '%s=%q\n' "$variable" "$value" >> "$env_file"
          echo "  Captured $variable for unattended Manul processes" >&2
        fi
        ;;
    esac
  done

  # Jira credentials may use operator-selected environment variable names.
  # Capture only names explicitly configured by enabled Jira task sources; never
  # copy arbitrary process environment variables into Manul runtime state.
  local jira_variable
  if [ -f "$runtime_dir/config.json" ]; then
    while IFS= read -r jira_variable; do
      [ -n "$jira_variable" ] || continue
      if [[ ! "$jira_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "  Ignoring invalid Jira environment variable name: $jira_variable" >&2
        continue
      fi
      value="${!jira_variable:-}"
      if [ -n "$value" ] && ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${jira_variable}=" "$env_file"; then
        printf "%s=%q\n" "$jira_variable" "$value" >> "$env_file"
        echo "  Captured $jira_variable for unattended Manul processes" >&2
      fi
    done < <(
      jq -r '
        .taskSources[]?
        | select((.enabled != false))
        | select(.type == "jira_tasks")
        | (.userEnv // "MANUL_JIRA_USER"), (.passwordEnv // "MANUL_JIRA_PASSWORD")
      ' "$runtime_dir/config.json" 2>/dev/null | sort -u
    )
  fi

  chmod 600 "$env_file" || return 1

  if ! bash -n "$env_file" >/dev/null 2>&1; then
    echo "ERROR: invalid shell syntax in generated Manul environment file: $env_file" >&2
    return 1
  fi

  printf '%s' "$env_file"
}

if [ "${1:-}" = "--bootstrap" ]; then
  [ "${2:-}" != "" ] || {
    echo "Usage: $0 --bootstrap <runtime-dir>" >&2
    exit 2
  }
  manul_env_bootstrap "$2"
elif [ "${1:-}" = "--load" ]; then
  [ "${2:-}" != "" ] || {
    echo "Usage: $0 --load <runtime-dir>" >&2
    exit 2
  }
  manul_env_load "$2"
fi
