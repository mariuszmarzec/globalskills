#!/usr/bin/env bash
# manul-env.sh — Load and bootstrap Manul operator environment.
#
# The daemon and watchdog can run from cron/systemd without a login shell, so
# provider-specific environment must not rely on ~/.zshrc.
#
# Runtime-owned environment file:
#   ~/.manul/.env
#
# The bootstrap operation preserves an existing .env and only adds supported
# provider settings that are present in the installer/repair process environment.
# It never copies arbitrary environment variables or secrets into runtime state.

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
# for example OPENCLAW_STATE_DIR and OPENCLAW_CONFIG_PATH.
#
# The installer only copies a small allowlist of provider variables from the
# current process environment. Existing entries are always preserved.
EOF
    then
      return 1
    fi
    chmod 600 "$env_file" || return 1
  fi

  local variable value
  for variable in \
    OPENCLAW_STATE_DIR \
    OPENCLAW_CONFIG_PATH \
    OPENCLAW_HOME \
    OPENCLAW_GATEWAY_PORT \
    OPENCLAW_BIN \
    OPENCODE_BIN; do
    value="${!variable:-}"
    if [ -n "$value" ] && ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${variable}=" "$env_file"; then
      printf '%s=%q\n' "$variable" "$value" >> "$env_file"
      echo "  Captured $variable for unattended Manul processes" >&2
    fi
  done

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
