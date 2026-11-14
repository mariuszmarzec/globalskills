#!/usr/bin/env bash
# Ensure canonical specialist agents are directly invokable and delegatable.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agents_dir="$ROOT_DIR/agents"
failed=0
for agent in "$agents_dir"/*.md; do
  name="$(basename "$agent")"
  mode="$(sed -n 's/^mode = "\(.*\)"$/\1/p' "$agent" | head -n 1)"
  if [ "$name" = "orchestrator.md" ]; then
    if [ "$mode" != "all" ]; then
      echo "FAIL: orchestrator.md must remain primary-invokable and delegatable (mode=all, got $mode)"
      failed=1
    else
      echo "PASS: orchestrator remains primary-invokable and delegatable"
    fi
  elif [ "$mode" != "all" ]; then
    echo "FAIL: $name must use mode: all for direct CLI and subagent use (got $mode)"
    failed=1
  else
    echo "PASS: $name uses mode: all"
  fi
done

if [ ! -f "$agents_dir/sdd.md" ]; then
  echo "FAIL: canonical SDD agent definition is missing"
  failed=1
else
  sdd_mode="$(sed -n 's/^mode = "\(.*\)"$/\1/p' "$agents_dir/sdd.md" | head -n 1)"
  if [ "$sdd_mode" != "all" ]; then
    echo "FAIL: sdd.md must use mode: all (got $sdd_mode)"
    failed=1
  else
    echo "PASS: SDD agent is directly invokable and delegatable"
  fi
fi

exit "$failed"
