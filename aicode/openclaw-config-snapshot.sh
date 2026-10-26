#!/usr/bin/env bash
# Helpers for reading and validating OpenClaw's config.get snapshot.
# Kept separate so the response parsing can be unit tested without a live Gateway.

openclaw_config_get_snapshot() {
    local response

    # Capture the CLI status directly. Do not pipe the command into tail: without
    # pipefail, a failed OpenClaw invocation could be hidden by a successful tail.
    if ! response="$(openclaw gateway call config.get --params '{}' 2>/dev/null)"; then
        return 1
    fi

    # Current OpenClaw CLI versions may print this advisory line to stdout before
    # the JSON payload. Strip it only when the exact known prefix is present;
    # valid raw JSON from a future CLI format must remain untouched.
    case "$response" in
        "Gateway call: config.get"$'\n'*)
            response="${response#*$'\n'}"
            ;;
    esac

    # Require exactly one JSON object and the two fields config.patch needs:
    # .config is the snapshot object and .hash is the raw-file revision token.
    # configRevisionHash/appliedConfigHash are different hashes and are not
    # valid substitutes for config.patch's optimistic-concurrency baseHash.
    if ! printf '%s\n' "$response" | jq -se '
        length == 1
        and (.[0] | type == "object")
        and (.[0].config | type == "object")
        and (.[0].hash | (type == "string" and length > 0))
    ' >/dev/null 2>&1; then
        return 1
    fi

    printf '%s\n' "$response"
}

# Read the exact file revision hash required by config.patch's baseHash.
# Input is a validated config.get JSON object on stdin.
openclaw_config_snapshot_base_hash() {
    jq -er '.hash | select(type == "string" and length > 0)'
}

# Emit the actual configuration object from a validated config.get response.
openclaw_config_snapshot_config() {
    jq -ce '.config | select(type == "object")'
}
