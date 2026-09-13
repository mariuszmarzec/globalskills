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

: "${PID_FILE:=/dev/null}"
get_daemon_pid() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
    echo "$pid"
  else
    echo "0"
  fi
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

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

workspace_pool_init() {
  local pool_size="${1:-$((MAX_CONCURRENT_TASKS / 1))}"
  local reset="${2:-}"
  workspace_init
  if [ "$reset" = "reset" ]; then
    sqlite3 "$DB" "DELETE FROM workspaces;" 2>/dev/null || true
  fi
  local current_size
  current_size="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces;" 2>/dev/null || echo 0)"
  local i
  for ((i = current_size; i < pool_size; i++)); do
    local ws_id="ws-$i-$(date +%s)"
    local ws_path="$WORKSPACES_DIR/$ws_id"
    mkdir -p "$ws_path"
    sqlite3 "$DB" "INSERT OR IGNORE INTO workspaces(workspaceId, workspacePath, status, lastUsedAt) VALUES('$ws_id', '$ws_path', 'IDLE', datetime('now'));"
  done
}

workspace_lease() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local result
  result="$(sqlite3 "$DB" "BEGIN IMMEDIATE; UPDATE workspaces SET status='BUSY', currentTaskId='$safe_task_id', lastUsedAt=datetime('now') WHERE workspaceId IN (SELECT workspaceId FROM workspaces WHERE status='IDLE' LIMIT 1); SELECT changes(); COMMIT;" 2>/dev/null)"
  if [ "${result:-0}" -eq 0 ]; then
    return 1
  fi
  sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null
}

workspace_release() {
  local ws_id="$1"
  local task_id="${2:-}"
  local safe_ws_id
  safe_ws_id="$(sql_escape "$ws_id")"
  local owns
  owns="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$safe_ws_id' AND status='BUSY';" 2>/dev/null)"
  if [ "${owns:-0}" -eq 0 ]; then
    return 1
  fi
  if [ -n "$task_id" ]; then
    local safe_task_id
    safe_task_id="$(sql_escape "$task_id")"
    local correct_owner
    correct_owner="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id';" 2>/dev/null)"
    if [ "${correct_owner:-0}" -eq 0 ]; then
      return 1
    fi
  fi
  sqlite3 "$DB" "UPDATE workspaces SET status='IDLE', currentTaskId=NULL WHERE workspaceId='$safe_ws_id';"
}

# Atomically reclaim a previously-used workspace for a task whose processed_comments row points to it.
workspace_reclaim() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local ws_id
  ws_id="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null)"
  [ -n "$ws_id" ] || return 1
  local safe_ws_id
  safe_ws_id="$(sql_escape "$ws_id")"
  local result
  result="$(sqlite3 "$DB" "BEGIN IMMEDIATE; UPDATE workspaces SET status='BUSY', currentTaskId='$safe_task_id', lastUsedAt=datetime('now') WHERE workspaceId='$safe_ws_id' AND (status='IDLE' OR (status='BUSY' AND currentTaskId='$safe_task_id')); SELECT changes(); COMMIT;" 2>/dev/null)"
  [ "${result:-0}" -eq 1 ] || return 1
  sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null
}

workspace_mark_broken() {
  local ws_id="$1"
  local safe_ws_id
  safe_ws_id="$(sql_escape "$ws_id")"
  sqlite3 "$DB" "UPDATE workspaces SET status='BROKEN' WHERE workspaceId='$safe_ws_id';"
  rm -rf "$WORKSPACES_DIR/$ws_id"
}

workspace_get_path() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local path
  path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
  if [ -z "$path" ]; then
    workspace_reclaim "$task_id" >/dev/null 2>&1 || true
    path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
  fi

  # Workspaces are pooled across repositories. Do not let a task inherit a different repo checkout.
  if [ -n "$path" ] && [ -d "$path/.git" ]; then
    local task_repo actual_repo expected_repo
    task_repo="$(sqlite3 "$DB" "SELECT repository FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null)"
    if [ -n "$task_repo" ]; then
      actual_repo="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
      expected_repo="https://github.com/${task_repo}"
      if [ "$actual_repo" != "$expected_repo" ]; then
        rm -rf "$path"/* "$path"/.[!.]* "$path"/..?* 2>/dev/null || true
      fi
    fi
  fi
  printf '%s\n' "$path"
}

workspace_cleanup_stale() {
  local stale_threshold="${1:-3600}"
  sqlite3 "$DB" "UPDATE workspaces SET status='BROKEN' WHERE status='BUSY' AND lastUsedAt < datetime('now', '-${stale_threshold} seconds');"
  sqlite3 "$DB" "DELETE FROM workspaces WHERE status='BROKEN' OR (lastUsedAt < datetime('now', '-${stale_threshold} seconds') AND status='IDLE');"
}

workspace_available_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='IDLE'"
}

workspace_busy_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='BUSY'"
}

export -f workspace_init workspace_pool_init workspace_lease workspace_release workspace_reclaim workspace_mark_broken workspace_get_path workspace_cleanup_stale workspace_available_count workspace_busy_count 2>/dev/null
