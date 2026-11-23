#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONPATH="$ROOT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -m unittest discover -s "$ROOT_DIR/installer/tests" -v

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Regression: the maintained aicode launcher must never retain CRLF.
bash "$ROOT_DIR/installer/test_aicode_line_endings.sh"
python3 "$ROOT_DIR/installer/globalskills.py" --source "$ROOT_DIR" --home "$TMP_DIR/home" --state-dir "$TMP_DIR/state" install --runtime all
python3 "$ROOT_DIR/installer/globalskills.py" --source "$ROOT_DIR" --home "$TMP_DIR/home" --state-dir "$TMP_DIR/state" status --runtime all
