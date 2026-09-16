#!/bin/bash
# test_runtime_health.sh — Regression tests for Manul runtime health/recovery

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
TMPROOT=""

cleanup() {
  if [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ]; then
    rm -rf "$TMPROOT"
  fi
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_cmd() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$description"
  else
    fail "$description"
  fi
}

echo "=== Runtime Health Tests ==="
echo "Canonical source: $SCRIPT_DIR"
echo ""

# Test 1: Shell syntax for the runtime/recovery scripts.
echo "Test 1: Shell syntax"
for script in \
  repair-manul-runtime.sh \
  install-manul-symlinks.sh \
  manul-daemon.sh \
  github-api-wrapper.sh \
  manul-conversation.sh \
  workspace-manager.sh \
  watchdog.sh \
  task-recovery.sh \
  task-health-check.sh; do
  assert_cmd "$script has valid shell syntax" bash -n "$SCRIPT_DIR/$script"
done

# Test 2: No old machine-specific runtime paths remain in executable scripts.
echo
 echo "Test 2: No hardcoded runtime paths"
HARDCODED_PATHS="$(grep -REn '(/home/marzec/\.openclaw/manul|/mnt/f/ubuntu-workspace/\.openclaw/manul)' \
  "$SCRIPT_DIR"/*.sh 2>/dev/null | grep -v 'test_runtime_health.sh' || true)"
if [ -z "$HARDCODED_PATHS" ]; then
  ok "No old absolute runtime paths found"
else
  fail "Old absolute runtime paths remain:\n$HARDCODED_PATHS"
fi

# Test 3: The installer exposes all runtime scripts and resolves its default path.
echo
echo "Test 3: Installer contract"
if grep -q 'RUNTIME_DIR="${MANUL_RUNTIME_DIR:-\$HOME/.openclaw/manul}"' "$SCRIPT_DIR/install-manul-symlinks.sh" 2>/dev/null; then
  ok "Installer default runtime is HOME/.openclaw/manul"
else
  fail "Installer default runtime is not HOME/.openclaw/manul"
fi

SCRIPT_COUNT=$(awk '/^SCRIPTS=\(/,/^\)/' "$SCRIPT_DIR/install-manul-symlinks.sh" | grep -c '^ *"' || true)
if [ "$SCRIPT_COUNT" -ge 20 ]; then
  ok "Installer declares $SCRIPT_COUNT runtime entries"
else
  fail "Installer declares only $SCRIPT_COUNT runtime entries (expected at least 20)"
fi

# Test 4: Isolated recovery without a backup must fail safely.
echo
echo "Test 4: Recovery without DB backup fails safely"
TMPROOT=$(mktemp -d /tmp/manul-runtime-test-XXXXXX)
MISSING_DB_RUNTIME="$TMPROOT/missing-db-runtime"
mkdir -p "$MISSING_DB_RUNTIME"

set +e
NO_BACKUP_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$MISSING_DB_RUNTIME" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
NO_BACKUP_EXIT=$?
set -e

if [ "$NO_BACKUP_EXIT" -eq 1 ] && echo "$NO_BACKUP_OUTPUT" | grep -q "No backup DB found"; then
  ok "Recovery exits 1 when DB backup is unavailable"
else
  fail "Recovery did not fail safely without DB backup (exit=$NO_BACKUP_EXIT)"
fi

if [ ! -f "$MISSING_DB_RUNTIME/manul.db" ]; then
  ok "No fabricated DB was created"
else
  fail "Recovery created a DB despite missing backup"
fi

if [ -L "$MISSING_DB_RUNTIME/manul-daemon.sh" ] && [ -f "$MISSING_DB_RUNTIME/config.json" ]; then
  ok "Failed recovery still prepares runtime links/config"
else
  fail "Failed recovery did not prepare expected runtime links/config"
fi

# Create a valid backup DB using the current canonical schema contract.
BACKUP_DB="$TMPROOT/backup/manul.db"
mkdir -p "$(dirname "$BACKUP_DB")"
sqlite3 "$BACKUP_DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  author TEXT,
  agent TEXT,
  prompt TEXT NOT NULL,
  context TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  nextAttemptAt TEXT,
  conversationId TEXT,
  parentTaskId TEXT,
  workspaceId TEXT,
  action TEXT DEFAULT 'IMPLEMENT',
  prNumber INTEGER,
  prUrl TEXT
);
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  issueUrl TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'OPEN',
  activeTaskId TEXT,
  activePrNumber TEXT,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE workspaces (
  workspaceId TEXT PRIMARY KEY,
  workspacePath TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'IDLE',
  currentTaskId TEXT,
  lastUsedAt TEXT
);
SQL

# Test 5: Recovery from an explicit backup succeeds.
echo
echo "Test 5: Recovery from explicit DB backup"
GOOD_RUNTIME="$TMPROOT/good-runtime"
set +e
GOOD_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$GOOD_RUNTIME" \
  MANUL_SOURCE_DB="$BACKUP_DB" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
GOOD_EXIT=$?
set -e

if [ "$GOOD_EXIT" -eq 0 ] && echo "$GOOD_OUTPUT" | grep -q "Repair Complete"; then
  ok "Recovery from backup completes successfully"
else
  fail "Recovery from backup failed (exit=$GOOD_EXIT)"
  echo "$GOOD_OUTPUT"
fi

if [ -f "$GOOD_RUNTIME/config.json" ] && jq empty "$GOOD_RUNTIME/config.json" >/dev/null 2>&1; then
  ok "Recovered config.json is valid JSON"
else
  fail "Recovered config.json is missing or invalid"
fi

# Test 6: All installed links exist and point into canonical source.
echo
echo "Test 6: Runtime symlinks"
LINK_FAILURES=0
LINK_COUNT=0
for entry in "$GOOD_RUNTIME"/*.sh "$GOOD_RUNTIME"/*.md; do
  [ -e "$entry" ] || continue
  [ -L "$entry" ] || { LINK_FAILURES=$((LINK_FAILURES + 1)); echo "  FAIL: not a symlink: $entry"; continue; }
  LINK_COUNT=$((LINK_COUNT + 1))
  target=$(readlink -f "$entry" 2>/dev/null || true)
  case "$target" in
    "$SCRIPT_DIR"/*) ;;
    *) LINK_FAILURES=$((LINK_FAILURES + 1)); echo "  FAIL: wrong target: $entry -> $target" ;;
  esac
done

if [ "$LINK_FAILURES" -eq 0 ] && [ "$LINK_COUNT" -ge 20 ]; then
  ok "$LINK_COUNT runtime symlinks valid and point to canonical source"
else
  fail "Runtime symlink check failed: $LINK_COUNT links, $LINK_FAILURES failures"
fi

# Test 7: Schema contains the required tables after canonical initialization.
echo
echo "Test 7: Recovered DB schema"
REQUIRED_TABLES="processed_comments conversations meta workspaces"
SCHEMA_FAILURES=0
for table in $REQUIRED_TABLES; do
  if ! sqlite3 "$GOOD_RUNTIME/manul.db" "SELECT 1 FROM $table LIMIT 1;" >/dev/null 2>&1; then
    SCHEMA_FAILURES=$((SCHEMA_FAILURES + 1))
    fail "Required table '$table' exists"
  fi
done
if [ "$SCHEMA_FAILURES" -eq 0 ]; then
  ok "All required tables exist"
fi

# Test 8: A second repair is successful and does not replace the DB.
echo
echo "Test 8: Repair idempotency"
DB_BEFORE=$(sha256sum "$GOOD_RUNTIME/manul.db" | awk '{print $1}')
CONFIG_BEFORE=$(sha256sum "$GOOD_RUNTIME/config.json" | awk '{print $1}')

set +e
SECOND_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$GOOD_RUNTIME" \
  MANUL_SOURCE_DB="$BACKUP_DB" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
SECOND_EXIT=$?
set -e

if [ "$SECOND_EXIT" -eq 0 ] && echo "$SECOND_OUTPUT" | grep -q "Repair Complete"; then
  ok "Second repair completes successfully"
else
  fail "Second repair failed (exit=$SECOND_EXIT)"
  echo "$SECOND_OUTPUT"
fi

DB_AFTER=$(sha256sum "$GOOD_RUNTIME/manul.db" | awk '{print $1}')
CONFIG_AFTER=$(sha256sum "$GOOD_RUNTIME/config.json" | awk '{print $1}')
if [ "$DB_BEFORE" = "$DB_AFTER" ]; then
  ok "Second repair preserved existing DB"
else
  fail "Second repair changed existing DB"
fi
if [ "$CONFIG_BEFORE" = "$CONFIG_AFTER" ]; then
  ok "Second repair preserved existing config"
else
  fail "Second repair changed existing config"
fi

# Test 9: Archive fallback works with the supported sibling archive layout.
echo
echo "Test 9: Archive DB fallback"
ARCHIVE_RUNTIME="$TMPROOT/archive-runtime"
ARCHIVE_DIR="$TMPROOT/archive-runtime-archive-20260917-000000"
mkdir -p "$ARCHIVE_DIR"
cp "$BACKUP_DB" "$ARCHIVE_DIR/manul.db"

set +e
ARCHIVE_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$ARCHIVE_RUNTIME" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
ARCHIVE_EXIT=$?
set -e

if [ "$ARCHIVE_EXIT" -eq 0 ] && echo "$ARCHIVE_OUTPUT" | grep -q "Restored DB from archive"; then
  ok "Recovery restores the newest sibling archive DB"
else
  fail "Archive DB fallback failed (exit=$ARCHIVE_EXIT)"
  echo "$ARCHIVE_OUTPUT"
fi

# Summary.
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
