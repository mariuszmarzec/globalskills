#!/usr/bin/env bash
# opencode-permissions.sh — ensure provider permissions required by Manul.
#
# OpenCode configuration remains provider-owned. This helper only applies the
# minimum permissions needed for unattended Manul execution and preserves all
# unrelated user configuration.
#
# Required rules (idempotent, additive):
#   /tmp/**                                  - scratch space for cloned repos
#   ~/.gradle/caches/modules-2/files-2.1/**  - dependency artifacts (JARs) that
#                                              agents must read to understand
#                                              library APIs. Scoped to the module
#                                              cache only, never the whole Gradle
#                                              home, which may hold credentials.

set -euo pipefail

# Required permission rules. Each entry is a jq path expression for the
# permission.external_directory key. The installer only ensures these exist;
# it never removes or rewrites any other rule.
REQUIRED_PERMISSION_RULES=(
  '.permission.external_directory["/tmp/**"] = "allow"'
  '.permission.external_directory["~/.gradle/caches/modules-2/files-2.1/**"] = "allow"'
)

# Paths verified against the effective OpenCode configuration, kept in lockstep
# with REQUIRED_PERMISSION_RULES above.
REQUIRED_PERMISSION_PATHS=(
  '/tmp/**'
  '~/.gradle/caches/modules-2/files-2.1/**'
)

resolve_opencode_bin() {
  if [ -n "${OPENCODE_BIN:-}" ] && [ -x "$OPENCODE_BIN" ]; then
    printf '%s' "$OPENCODE_BIN"
    return 0
  fi
  local found=""
  found="$(command -v opencode 2>/dev/null || true)"
  if [ -n "$found" ] && [ -x "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  if [ -x "$HOME/.opencode/bin/opencode" ]; then
    printf '%s' "$HOME/.opencode/bin/opencode"
    return 0
  fi
  return 1
}

OPENCODE_BIN_RESOLVED="$(resolve_opencode_bin || true)"
[ -n "$OPENCODE_BIN_RESOLVED" ] || exit 0

# Provider configuration is owned by OpenCode/the operator. Respect an
# explicitly configured OPENCODE_CONFIG; fall back to the canonical default.
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

# Provider configuration is owned by OpenCode/the operator. Manul must not
# invent a new provider config just to add its permission rule; a missing
# provider config is a safe no-op.
[ -f "$OPENCODE_CONFIG" ] || exit 0

CONFIG_DIR="$(dirname "$OPENCODE_CONFIG")"
if ! jq empty "$OPENCODE_CONFIG" >/dev/null 2>&1; then
  echo "ERROR: invalid OpenCode configuration: $OPENCODE_CONFIG" >&2
  exit 1
fi

TMP_FILE="$(mktemp "$CONFIG_DIR/.opencode.manul.XXXXXX")"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT

# Build the jq expression once so the rule set lives in one place and stays in
# sync with REQUIRED_PERMISSION_RULES. Assignment is idempotent: re-running on
# an existing rule is a no-op, so unrelated settings are never touched.
JQ_EXPR='.'
for rule in "${REQUIRED_PERMISSION_RULES[@]}"; do
  JQ_EXPR="$JQ_EXPR | $rule"
done

# shellcheck disable=SC2086
jq "$JQ_EXPR" "$OPENCODE_CONFIG" >"$TMP_FILE"
MODE="$(stat -c '%a' "$OPENCODE_CONFIG" 2>/dev/null || true)"
[ -n "$MODE" ] && chmod "$MODE" "$TMP_FILE" 2>/dev/null || true

if ! jq empty "$TMP_FILE" >/dev/null 2>&1; then
  echo "ERROR: generated OpenCode configuration is invalid" >&2
  exit 1
fi

if ! cmp -s "$OPENCODE_CONFIG" "$TMP_FILE"; then
  mv -f "$TMP_FILE" "$OPENCODE_CONFIG"
fi

# Confirm the effective provider configuration agrees with every required rule.
for i in "${!REQUIRED_PERMISSION_PATHS[@]}"; do
  path="${REQUIRED_PERMISSION_PATHS[$i]}"
  if ! "$OPENCODE_BIN_RESOLVED" debug config 2>/dev/null |
    jq -e --arg p "$path" '.permission.external_directory[$p] == "allow"' >/dev/null 2>&1; then
    echo "ERROR: OpenCode effective configuration does not allow $path" >&2
    exit 1
  fi
done