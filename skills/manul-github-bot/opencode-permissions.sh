#!/usr/bin/env bash
# opencode-permissions.sh — ensure provider permissions required by Manul.
#
# OpenCode configuration remains provider-owned. This helper only applies the
# minimum permission needed for unattended Manul execution and preserves all
# unrelated user configuration.

set -euo pipefail

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

OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
CONFIG_DIR="$(dirname "$OPENCODE_CONFIG")"
mkdir -p "$CONFIG_DIR"

CONFIG_EXISTS=false
if [ -f "$OPENCODE_CONFIG" ]; then
  CONFIG_EXISTS=true
  if ! jq empty "$OPENCODE_CONFIG" >/dev/null 2>&1; then
    echo "ERROR: invalid OpenCode configuration: $OPENCODE_CONFIG" >&2
    exit 1
  fi
fi

TMP_FILE="$(mktemp "$CONFIG_DIR/.opencode.manul.XXXXXX")"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT

if [ "$CONFIG_EXISTS" = true ]; then
  jq '.permission.external_directory["/tmp/**"] = "allow"' \
    "$OPENCODE_CONFIG" >"$TMP_FILE"
  MODE="$(stat -c '%a' "$OPENCODE_CONFIG" 2>/dev/null || true)"
  [ -n "$MODE" ] && chmod "$MODE" "$TMP_FILE" 2>/dev/null || true
else
  jq -n '{permission:{external_directory:{"/tmp/**":"allow"}}}' >"$TMP_FILE"
  chmod 600 "$TMP_FILE"
fi

if ! jq empty "$TMP_FILE" >/dev/null 2>&1; then
  echo "ERROR: generated OpenCode configuration is invalid" >&2
  exit 1
fi

if [ "$CONFIG_EXISTS" = false ] || ! cmp -s "$OPENCODE_CONFIG" "$TMP_FILE"; then
  mv -f "$TMP_FILE" "$OPENCODE_CONFIG"
fi

# Confirm the effective provider configuration agrees with the required rule.
if ! "$OPENCODE_BIN_RESOLVED" debug config 2>/dev/null |
  jq -e '.permission.external_directory["/tmp/**"] == "allow"' >/dev/null 2>&1; then
  echo "ERROR: OpenCode effective configuration does not allow /tmp/**" >&2
  exit 1
fi
