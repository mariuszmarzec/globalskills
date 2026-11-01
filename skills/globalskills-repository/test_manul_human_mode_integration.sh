#!/usr/bin/env bash
# Host-side integration guard for Manul human mode and AI commit attribution.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTRIBUTION_SKILL="$SCRIPT_DIR/../ai-commit-attribution/SKILL.md"

if [ ! -f "$ATTRIBUTION_SKILL" ]; then
  echo "FAIL: AI commit attribution skill is missing: $ATTRIBUTION_SKILL" >&2
  exit 1
fi

if ! grep -q 'mode: "human"' "$ATTRIBUTION_SKILL"; then
  echo "FAIL: commit attribution skill has no human-mode exception" >&2
  exit 1
fi

echo "PASS: globalskills commit attribution documents Manul human-mode exception"
