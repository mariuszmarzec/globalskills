#!/usr/bin/env bash
# opencode-permissions.sh — ensure provider permissions required by Manul.
#
# OpenCode configuration remains provider-owned. This helper only applies the
# minimum permission needed for unattended Manul execution and preserves all
# unrelated user configuration.

set -euo pipefail

OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode 2>/dev/null || true)}"

if [ -z "$OPENCODE_BIN" ] || [ ! -x "$OPENCODE_BIN" ]; then
  exit 0
fi

if [ ! -f "$OPENCODE_CONFIG" ]; then
  exit 0
fi

if ! jq empty "$OPENCODE_CONFIG" >/dev/null 2>&1; then
  echo "ERROR: invalid OpenCode configuration: $OPENCODE_CONFIG" >&2
  exit 1
fi

TMP_FILE="$(mktemp "${OPENCODE_CONFIG}.manul.XXXXXX")"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT

jq '.permission.external_directory["/tmp/**"] = "allow"' \
  "$OPENCODE_CONFIG" >"$TMP_FILE"

if ! jq empty "$TMP_FILE" >/dev/null 2>&1; then
  echo "ERROR: generated OpenCode configuration is invalid" >&2
  exit 1
fi

if ! cmp -s "$OPENCODE_CONFIG" "$TMP_FILE"; then
  mv "$TMP_FILE" "$OPENCODE_CONFIG"
fi

# Confirm the effective provider configuration agrees with the required rule.
if ! "$OPENCODE_BIN" debug config 2>/dev/null |
  jq -e '.permission.external_directory["/tmp/**"] == "allow"' >/dev/null 2>&1; then
  echo "ERROR: OpenCode effective configuration does not allow /tmp/**" >&2
  exit 1
fi
