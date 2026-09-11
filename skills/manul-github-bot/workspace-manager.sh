#!/bin/bash
# workspace-manager.sh: Manages workspace leasing for concurrency
#
# Provides functions for:
# - Creating and managing a pool of isolated workspaces
# - Leasing workspaces to tasks for exclusive access
# - Releasing workspaces back to the pool
# - Cleaning up broken workspaces

MANUL_DIR="${MANUL_DIR:-${OPENCLAW_MANUL_DIR:-$HOME/.openclaw/manul}}"
DB="$MANUL_DIR/manul.db"
WORKSPACES_DIR="${MANUL_DIR}/workspaces"

# Default PID_FILE if not set (needed for get_daemon_pid)
: "${PID_FILE:=/dev/null}"

# Get daemon PID (compatible with manul-daemon.sh)
get_daemon_pid() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
    echo "$pid"
  else
    echo "0"
  fi
}

# Initialize workspace table if it doesn't exist
workspace_init() {
  mkdir -p "$WORKSPACES_DIR"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS workspaces (
    workspaceId TEXT PRIMARY KEY,
    workspacePath TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'IDLE',
    currentTaskId TEXT,
    lastUsedAt TEXT
  );"
}

# Create a new workspace in the pool
# Arguments: $1 = pool_size (number of workspaces to create)
#             $2 = reset (optional, "reset" clears existing pool - for testing only)
workspace_pool_init() {
  local pool_size="${1:-$((MAX_CONCURRENT_TASKS / 1))}"
  local reset="${2:-}"

  # Initialize table
  workspace_init

  # Reset pool if requested (testing only)
  if [ "$reset" = "reset" ]; then
    sqlite3 "$DB" "DELETE FROM workspaces;" 2>/dev/null || true
  fi

  # Get current pool size
  local current_size
  current_size="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces;" 2>/dev/null || echo 0)"

  # Only add missing workspaces — never destroy existing pool state
  local i
  for ((i = current_size; i < pool_size; i++)); do
    local ws_id="ws-$i-$(date +%s)"
    local ws_path="$WORKSPACES_DIR/$ws_id"
    mkdir -p "$ws_path"
    sqlite3 "$DB" "INSERT OR IGNORE INTO workspaces(workspaceId, workspacePath, status, lastUsedAt) VALUES('$ws_id', '$ws_path', 'IDLE', datetime('now'));"
  done
}

# Lease a workspace to a task
# Returns: workspaceId on success, empty on failure
# Arguments: $1 = task_id
workspace_lease() {
  local task_id="$1"

  # Atomic SELECT+UPDATE using changes() to prevent TOCTOU race
  # This performs the selection and update in a single transaction
  local result
  result="$(sqlite3 "$DB" "
    BEGIN IMMEDIATE;
    UPDATE workspaces SET status='BUSY', currentTaskId='$task_id', lastUsedAt=datetime('now')
    WHERE workspaceId IN (SELECT workspaceId FROM workspaces WHERE status='IDLE' LIMIT 1);
    SELECT changes();
    COMMIT;
  " 2>/dev/null)"

  if [ "${result:-0}" -eq 0 ]; then
    return 1
  fi

  # Return the workspaceId that was just updated
  sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE currentTaskId='$task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null
}

# Release a workspace back to the pool
# Verifies ownership before releasing to prevent unauthorized releases
# Arguments: $1 = workspace_id, $2 = task_id (optional, for ownership verification)
workspace_release() {
  local ws_id="$1"
  local task_id="${2:-}"

  # Verify workspace exists and is BUSY
  local owns
  owns="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$ws_id' AND status='BUSY';" 2>/dev/null)"

  if [ "${owns:-0}" -eq 0 ]; then
    return 1
  fi

  # If task_id provided, verify ownership
  if [ -n "$task_id" ]; then
    local correct_owner
    correct_owner="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$ws_id' AND currentTaskId='$task_id';" 2>/dev/null)"
    if [ "${correct_owner:-0}" -eq 0 ]; then
      return 1
    fi
  fi

  sqlite3 "$DB" "UPDATE workspaces SET status='IDLE', currentTaskId=NULL WHERE workspaceId='$ws_id';"
}

# Mark a workspace as broken and remove it
# Arguments: $1 = workspace_id
workspace_mark_broken() {
  local ws_id="$1"
  sqlite3 "$DB" "UPDATE workspaces SET status='BROKEN' WHERE workspaceId='$ws_id';"
  rm -rf "$WORKSPACES_DIR/$ws_id"
}

# Get workspace path for a task
# Arguments: $1 = task_id
# Returns: workspace_path or empty
workspace_get_path() {
  local task_id="$1"
  sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE currentTaskId='$task_id' AND status='BUSY';"
}

# Clean up stale workspaces (not used for N seconds)
# Arguments: $1 = stale_threshold_seconds (default: 3600)
workspace_cleanup_stale() {
  local stale_threshold="${1:-3600}"
  sqlite3 "$DB" "UPDATE workspaces SET status='BROKEN' WHERE status='BUSY' AND lastUsedAt < datetime('now', '-${stale_threshold} seconds');"
  sqlite3 "$DB" "DELETE FROM workspaces WHERE status='BROKEN' OR (lastUsedAt < datetime('now', '-${stale_threshold} seconds') AND status='IDLE');"
}

# Get available workspace count
workspace_available_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='IDLE';"
}

# Get busy workspace count
workspace_busy_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='BUSY';"
}

# Export functions
export -f workspace_init workspace_pool_init workspace_lease workspace_release workspace_mark_broken workspace_get_path workspace_cleanup_stale workspace_available_count workspace_busy_count 2>/dev/null
