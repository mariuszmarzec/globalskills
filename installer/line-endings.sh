#!/usr/bin/env bash
# Helpers for keeping executable shell entry points in Unix LF format.

ensure_user_executable() {
    local target="${1:?Usage: ensure_user_executable PATH}"
    if [ ! -f "$target" ]; then
        echo "ERROR: expected a regular launcher file: $target" >&2
        return 1
    fi
    chmod u+x -- "$target"
}

normalize_lf_file() {
    local target="${1:?Usage: normalize_lf_file PATH}"
    local carriage_return temporary_file grep_status

    if [ ! -f "$target" ] || [ -L "$target" ]; then
        echo "ERROR: expected a regular file to normalize: $target" >&2
        return 1
    fi

    carriage_return="$(printf '\r')"
    if LC_ALL=C grep -q "$carriage_return" "$target"; then
        :
    else
        grep_status=$?
        if [ "$grep_status" -eq 1 ]; then
            return 0
        fi
        echo "ERROR: could not inspect line endings in $target" >&2
        return "$grep_status"
    fi

    # Keep the temporary file beside the target so the final rename stays on
    # the same filesystem. cp -p preserves executable mode and permissions.
    temporary_file="$(mktemp "${target}.tmp.XXXXXX")" || return 1
    if ! cp -p "$target" "$temporary_file"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    if ! tr -d '\r' < "$target" > "$temporary_file"; then
        rm -f -- "$temporary_file"
        return 1
    fi
    if ! mv -f -- "$temporary_file" "$target"; then
        rm -f -- "$temporary_file"
        return 1
    fi
}
