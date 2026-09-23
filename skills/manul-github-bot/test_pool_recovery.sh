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

echo "Test 3: BUSY workspace for queued task is reclaimed immediately"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts) VALUES ('queued-task','test/repo',2,'queued',1);"
ws_queued="ws-queued"
ws_path="$MANUL_DIR/workspaces/$ws_queued"
mkdir -p "$ws_path"
sqlite3 "$DB" "INSERT INTO workspaces(workspaceId,workspacePath,status,currentTaskId,lastUsedAt) VALUES ('$ws_queued','$ws_path','BUSY','queued-task',datetime('now'));"
workspace_cleanup_stale 3600
status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws_queued';")"
[ -z "$status" ]
echo "PASS 4"

echo "Test 4: empty pool is recreated by ensure_workspace_pool"
sqlite3 "$DB" "DELETE FROM workspaces;"
# The production daemon sources the runtime copy/symlink of workspace-manager.sh.
# Reproduce that runtime layout inside the isolated test directory.
cp "$SCRIPT_DIR/workspace-manager.sh" "$MANUL_DIR/workspace-manager.sh"
set +e
MANUL_TESTING=true source "$SCRIPT_DIR/manul-daemon.sh"
source_rc=$?
set -e
if [ "$source_rc" -ne 0 ]; then
  echo "FAIL 4: sourcing daemon returned rc=$source_rc" >&2
  cat "$LIFECYCLE_LOG" 2>/dev/null || true
  exit 1
fi
set +e
enforce_rc=0
env | grep -q "^MAX_CONCURRENT_TASKS=" || true
enforce_rc=0
ensure_workspace_pool
pool_rc=$?
set -e
if [ "$pool_rc" -ne 0 ]; then
  echo "FAIL 4: ensure_workspace_pool returned rc=$pool_rc" >&2
  cat "$LIFECYCLE_LOG" 2>/dev/null || true
  exit 1
fi
count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status IN ('IDLE','BUSY');")"
[ "$count" -ge 1 ]
echo "PASS 3"

echo "All workspace pool recovery tests passed."