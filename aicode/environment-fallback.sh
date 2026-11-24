#!/usr/bin/env bash
# Shared environment-file fallback loader for aicode and the OpenCode ACP wrapper.
# Source this file, then call aicode_load_environment_fallback <path>.

aicode_load_environment_fallback() {
    local env_file="${1:?environment file path required}"
    [ -f "$env_file" ] || return 0
    if ! bash -n "$env_file" >/dev/null 2>&1; then
        echo "WARNING: ignoring invalid environment fallback: $env_file" >&2
        return 0
    fi

    set -a
    # shellcheck disable=SC1090
    . <(awk '
        BEGIN {
            for (name in ENVIRON) inherited[name] = 1
        }
        {
            candidate = $0
            sub(/^[[:space:]]*/, "", candidate)
            sub(/^export[[:space:]]+/, "", candidate)
            name = ""
            if (match(candidate, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
                name = substr(candidate, 1, index(candidate, "=") - 1)
            }
            # Only simple assignments are accepted from these legacy/service
            # files. The operator shell wins and PATH is never sourced here.
            value = substr(candidate, index(candidate, "=") + 1)
            # These files are dotenv-style assignments, not executable shell
            # scripts. Reject shell operators/command substitutions rather
            # than sourcing a line that could run an extra command.
            if (value ~ /[;&|\x60]/ || value ~ /\\$\\(/) next
            if (name == "" || name == "PATH" || name in inherited) next
            print
        }
    ' "$env_file")
    set +a
}
