#!/usr/bin/env bash
# manul-queue-reset.sh — Replay recoverable Manul queue items from configured sources.
#
# Default mode is a read-only preview. Execution removes only unfinished tasks
# that polling can recreate, clears the matching trigger-message dedupe records,
# makes a consistent SQLite backup, and runs poll.sh once.
# Running/completed/user-blocked tasks and manually submitted CLI tasks survive.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"

DB="${DB:-$MANUL_DB}"
POLL_SCRIPT="${MANUL_POLL_SCRIPT:-$MANUL_DIR/poll.sh}"
MODE="dry-run"

usage() {
  cat <<'USAGE'
Usage: manul-queue-reset.sh [--dry-run|--execute]

  --dry-run   Preview replayable queued/failed/stale tasks (default)
  --execute   Require confirmation, back up the DB, remove replayable tasks,
              clear their trigger-message dedupe entries, then run poll.sh

The install baseline and task history are not reset. Running/completed/
blocked-user tasks and manually submitted CLI tasks are preserved.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for cmd in sqlite3 flock; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

[ -f "$DB" ] || fail "Manul database not found: $DB"
sqlite3 "$DB" "PRAGMA integrity_check;" 2>/dev/null | grep -qx "ok" || fail "database integrity check failed: $DB"
sqlite3 "$DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='processed_comments';" 2>/dev/null | grep -qx "1" || fail "processed_comments table is missing"
[ -f "$POLL_SCRIPT" ] || fail "poll script not found: $POLL_SCRIPT"

has_column() {
  local table="$1" column="$2"
  sqlite3 "$DB" "PRAGMA table_info($table);" 2>/dev/null |
    awk -F'|' -v wanted="$column" '$2 == wanted { found=1 } END { exit !found }'
}

has_table() {
  sqlite3 "$DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$1';" 2>/dev/null | grep -qx "1"
}

SOURCE_PREDICATE="0"
if has_column processed_comments taskSourceType && has_column processed_comments taskSourceId; then
  SOURCE_PREDICATE="(taskSourceType IN ('github_issues','jira_tasks') AND COALESCE(taskSourceId,'') <> '')"
fi

# Only include GitHub comment IDs that poll.sh can rediscover. Never delete
# arbitrary comment-like IDs or user-submitted tasks that have no source trigger.
GITHUB_COMMENT_PREDICATE="(
  COALESCE(taskSourceType,'') = '' AND (
    (
      commentId <> '' AND commentId NOT GLOB '*[^0-9]*' AND
      (commentUrl LIKE 'https://github.com/%#issuecomment-%' OR commentUrl LIKE 'https://github.com/%#discussion_r%')
    ) OR (
      commentId LIKE 'review:%' AND substr(commentId,8) <> '' AND
      substr(commentId,8) NOT GLOB '*[^0-9]*' AND
      commentUrl LIKE 'https://github.com/%#discussion_r%'
    )
  )
)"
if ! has_column processed_comments taskSourceType; then
  GITHUB_COMMENT_PREDICATE="(
    (
      commentId <> '' AND commentId NOT GLOB '*[^0-9]*' AND
      (commentUrl LIKE 'https://github.com/%#issuecomment-%' OR commentUrl LIKE 'https://github.com/%#discussion_r%')
    ) OR (
      commentId LIKE 'review:%' AND substr(commentId,8) <> '' AND
      substr(commentId,8) NOT GLOB '*[^0-9]*' AND
      commentUrl LIKE 'https://github.com/%#discussion_r%'
    )
  )"
fi

CANDIDATE_PREDICATE="status IN ('queued','failed','stale') AND (($SOURCE_PREDICATE) OR $GITHUB_COMMENT_PREDICATE)"

show_counts() {
  echo "$1"
  sqlite3 "$DB" "
    SELECT '  replayable_' || status || '=' || COUNT(*)
    FROM processed_comments
    WHERE $CANDIDATE_PREDICATE
    GROUP BY status
    ORDER BY status;
    SELECT '  replayable_total=' || COUNT(*)
    FROM processed_comments WHERE $CANDIDATE_PREDICATE;
    SELECT '  running_preserved=' || COUNT(*)
    FROM processed_comments WHERE status='running';
    SELECT '  completed_preserved=' || COUNT(*)
    FROM processed_comments WHERE status IN ('done','completed');
    SELECT '  blocked_user_preserved=' || COUNT(*)
    FROM processed_comments WHERE status='blocked_user';
    SELECT '  manual_or_unreplayable_preserved=' || COUNT(*)
    FROM processed_comments WHERE status IN ('queued','failed','stale')
      AND NOT ($SOURCE_PREDICATE OR $GITHUB_COMMENT_PREDICATE);
  " 2>/dev/null
}

if [ "$MODE" = "dry-run" ]; then
  show_counts "Manul queue reset preview (read-only):"
  echo "No changes made. Run with --execute to rebuild the replayable queue."
  exit 0
fi

read -r -p "This replays unfinished externally-sourced tasks. Type RESET QUEUE to continue: " CONFIRMATION
[ "$CONFIRMATION" = "RESET QUEUE" ] || fail "confirmation did not match; no changes made"

mkdir -p "$MANUL_LOCKS_DIR" "$MANUL_STATE_DIR/backups"
POLL_LOCK_FILE="$MANUL_LOCKS_DIR/poll.flock"
exec 200>"$POLL_LOCK_FILE"
flock -n 200 || fail "poll.sh is already running; retry after the current poll finishes"

BACKUP_FILE="$MANUL_STATE_DIR/backups/manul-queue-reset-$(date -u +%Y%m%dT%H%M%SZ)-$$.db"
backup_database() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$DB" "$BACKUP_FILE" <<'PY'
import sqlite3
import sys

source_path, backup_path = sys.argv[1], sys.argv[2]
with sqlite3.connect(source_path, timeout=30) as source:
    with sqlite3.connect(backup_path, timeout=30) as destination:
        source.backup(destination)
        result = destination.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            raise SystemExit(f"backup integrity check failed: {result}")
PY
  else
    local quoted
    quoted="$(printf '%s' "$BACKUP_FILE" | sed "s/'/''/g")"
    sqlite3 "$DB" ".backup '$quoted'"
    sqlite3 "$BACKUP_FILE" "PRAGMA integrity_check;" | grep -qx "ok"
  fi
}
backup_database || fail "could not create a verified database backup"
echo "Backup: $BACKUP_FILE"

BASE_EXPR="NULL"
has_column processed_comments baseId && BASE_EXPR="baseId"
TYPE_EXPR="''"
has_column processed_comments taskSourceType && TYPE_EXPR="COALESCE(taskSourceType,'')"
HAS_MESSAGES=0
has_table conversation_messages && HAS_MESSAGES=1

MESSAGE_DELETE_SQL=""
if [ "$HAS_MESSAGES" -eq 1 ]; then
  MESSAGE_DELETE_SQL="DELETE FROM conversation_messages
WHERE commentId IN (SELECT commentId FROM queue_reset_candidates)
   OR commentId IN (SELECT baseId FROM queue_reset_candidates WHERE baseId IS NOT NULL)
   OR commentId IN (SELECT substr(commentId,8) FROM queue_reset_candidates WHERE commentId LIKE 'review:%');"
fi

# Selection and deletion share one write transaction. If a worker claimed a
# queued item before BEGIN IMMEDIATE, the task is now running and is not selected.
SQL_OUTPUT="$(
  sqlite3 -bail "$DB" <<SQL
BEGIN IMMEDIATE;
CREATE TEMP TABLE queue_reset_candidates AS
  SELECT commentId, $BASE_EXPR AS baseId, $TYPE_EXPR AS taskSourceType
  FROM processed_comments
  WHERE $CANDIDATE_PREDICATE;
SELECT 'candidate_count=' || COUNT(*) FROM queue_reset_candidates;
$MESSAGE_DELETE_SQL
DELETE FROM processed_comments
WHERE commentId IN (SELECT commentId FROM queue_reset_candidates)
  AND status IN ('queued','failed','stale');
SELECT 'deleted_tasks=' || changes();
DROP TABLE queue_reset_candidates;
COMMIT;
SQL
)" || fail "could not reset replayable tasks"

CANDIDATE_COUNT="$(printf '%s\n' "$SQL_OUTPUT" | sed -n 's/^candidate_count=//p' | tail -n1)"
DELETED_TASKS="$(printf '%s\n' "$SQL_OUTPUT" | sed -n 's/^deleted_tasks=//p' | tail -n1)"
CANDIDATE_COUNT="${CANDIDATE_COUNT:-0}"
DELETED_TASKS="${DELETED_TASKS:-0}"
[[ "$CANDIDATE_COUNT" =~ ^[0-9]+$ ]] || fail "could not read candidate count"
[[ "$DELETED_TASKS" =~ ^[0-9]+$ ]] || fail "could not read deleted task count"

flock -u 200 || true
exec 200>&-

echo "Replayable tasks found: $CANDIDATE_COUNT"
echo "Removed replayable tasks: $DELETED_TASKS"
echo "Preserved running workers, completed tasks, blocked-user tasks, manual submissions, conversations, workspace state, and baseline."
echo "Running the configured poller now..."

POLL_OUTPUT=""
POLL_EXIT=0
POLL_OUTPUT="$(MANUL_DIR="$MANUL_DIR" MANUL_DB="$DB" DB="$DB" bash "$POLL_SCRIPT" 2>&1)" || POLL_EXIT=$?
printf '%s\n' "$POLL_OUTPUT"

if [ "$POLL_EXIT" -ne 0 ]; then
  echo "ERROR: poll.sh exited with status $POLL_EXIT. Backup: $BACKUP_FILE" >&2
  exit "$POLL_EXIT"
fi

RESULT_JSON="$(printf '%s\n' "$POLL_OUTPUT" | sed -n 's/^MANUL_RESULT //p' | tail -n1)"
if [ -n "$RESULT_JSON" ] && printf '%s' "$RESULT_JSON" | jq -e '.error != null' >/dev/null 2>&1; then
  echo "ERROR: poller reported an error. Backup: $BACKUP_FILE" >&2
  exit 1
fi

echo
echo "Queue after poll:"
sqlite3 "$DB" "
  SELECT '  queued=' || COUNT(*) FROM processed_comments WHERE status='queued';
  SELECT '  running=' || COUNT(*) FROM processed_comments WHERE status='running';
  SELECT '  failed=' || COUNT(*) FROM processed_comments WHERE status='failed';
"
echo "Reset/re-poll complete. Backup retained at: $BACKUP_FILE"
