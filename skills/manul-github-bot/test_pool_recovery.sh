#!/bin/bash
# test_pool_recovery.sh — regression tests for long-lived Manul workspace pools.
#
# Tests:
# 1. Releasing a workspace refreshes lastUsedAt.
# 2. A recently released idle workspace survives stale cleanup.
# 3. A missing workspace pool is recreated by ensure_workspace_pool.
#
# Usage: bash test_pool_recovery.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/manul.db"
CONFIG="$MANUL_DIR/config.json"
LOG="$MANUL_DIR/daemon.log"
LIFECYCLE_LOG="$MANUL_DIR/lifecycle.log"
export MANUL_DIR DB CONFIG LOG LIFECYCLE_LOG MANUL_TESTING=true
mkdir -p "$MANUL_DIR/workspaces" "$MANUL_DIR/tasks"

cat >"$CONFIG" <<'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "automation": {
    "enabled": true,
    "maxConcurrentTasks": 1,
    "maxAttemptsBeforeFail": 3,
    "leaseTimeout": 900
  }
}
CONFIGEOF

sqlite3 "$DB" "CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL DEFAULT 'test/repo',
  issueNumber INTEGER NOT NULL DEFAULT 1,
  commentUrl TEXT NOT NULL DEFAULT 'https://github.com/test/repo/issues/1',
  prompt TEXT NOT NULL DEFAULT 'test',
  context TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT
);"

source "$SCRIPT_DIR/workspace-manager.sh"

echo "Test 1: workspace_release refreshes lastUsedAt"
workspace_pool_init 1 reset
ws="$(workspace_lease "release-refresh")"
[ -n "$ws" ]
old_ts="$(sqlite3 "$DB" "SELECT lastUsedAt FROM workspaces WHERE workspaceId='$ws';")"
sleep 1
workspace_release "$ws"
new_ts="$(sqlite3 "$DB" "SELECT lastUsedAt FROM workspaces WHERE workspaceId='$ws';")"
[ -n "$new_ts" ] && [ "$new_ts" != "$old_ts" ]
echo "PASS 1"

echo "Test 2: recently released idle workspace survives stale cleanup"
workspace_cleanup_stale 3600
status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws';")"
[ "$status" = "IDLE" ]
echo "PASS 2"

echo "Test 3: empty pool is recreated by ensure_workspace_pool"
sqlite3 "$DB" "DELETE FROM workspaces;"
# The production daemon sources the runtime copy/symlink of workspace-manager.sh.
# Reproduce that runtime layout inside the isolated test directory.
cp "$SCRIPT_DIR/workspace-manager.sh" "$MANUL_DIR/workspace-manager.sh"
MANUL_TESTING=true source "$SCRIPT_DIR/manul-daemon.sh"
set +e
ensure_workspace_pool
pool_rc=$?
set -e
if [ "$pool_rc" -ne 0 ]; then
  echo "FAIL 3: ensure_workspace_pool returned rc=$pool_rc" >&2
  cat "$LIFECYCLE_LOG" 2>/dev/null || true
  exit 1
fi
count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status IN ('IDLE','BUSY');")"
[ "$count" -ge 1 ]
echo "PASS 3"

echo "All workspace pool recovery tests passed."
