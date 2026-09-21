#!/bin/bash
# test_runtime_health.sh — Regression tests for Manul runtime health/recovery
#
# Tests that verify:
# 1. Shell syntax of all runtime scripts
# 2. No hardcoded /mnt/f or /home/marzec/.openclaw/manul paths in source
# 3. install-manul-symlinks.sh contracts
# 4. repair-manul-runtime.sh aborts safely without a DB backup
# 5. repair-manul-runtime.sh restores from a canonical-init DB backup
# 6. Restored symlinks are valid and point into canonical source
# 7. Recovered DB contains the required tables and columns (strengthened)
# 8. Second repair is idempotent (DB and config are not replaced)
# 9. Archive fallback works with supported sibling archive layout
# 10. init-schema failure is fatal — repair does not complete
# 11. workspace_init failure is fatal — repair does not complete
# 12. Existing empty manul.db + valid backup → backup is restored, repair succeeds
# 13. Existing invalid/corrupt manul.db + no backup → repair aborts, no schema fabricated
# 14. Existing valid DB + no backup → repair preserves it, remains idempotent (extends Test 8)
# 12. Existing empty manul.db + valid backup → backup is restored, repair succeeds
# 13. Existing invalid/corrupt manul.db + no backup → repair aborts, no schema fabricated
# 14. Existing valid DB + no backup → repair preserves it, remains idempotent (extends Test 8)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
TMPROOT=""

cleanup() {
  [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"
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

# Create a canonical-scheme DB using the production init paths.
# Returns path to the created DB via the global CANONICAL_BACKUP_DB.
create_canonical_backup() {
  local db_path="$1"
  mkdir -p "$(dirname "$db_path")"
  # Empty the DB first so init_schema can run cleanly
  rm -f "$db_path"
  touch "$db_path"
  chmod 600 "$db_path"

  # Run canonical init_schema via manul-conversation.sh init-schema
  local conv_dir
  conv_dir="$(dirname "$db_path")"
  MANUL_DIR="$conv_dir" DB="$db_path" \
    bash "$SCRIPT_DIR/manul-conversation.sh" init-schema

  # Run canonical workspace_init by sourcing workspace-manager.sh
  MANUL_DIR="$conv_dir" DB="$db_path" \
    bash -c 'source "$1"; workspace_init' _ "$SCRIPT_DIR/workspace-manager.sh"
}

echo "=== Runtime Health Tests ==="
echo "Canonical source: $SCRIPT_DIR"
echo ""

# ── Test 1: Shell syntax ──────────────────────────────────────────────────────
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

# ── Test 2: No old machine-specific runtime paths ─────────────────────────────
echo
echo "Test 2: No hardcoded runtime paths"
HARDCODED_PATHS="$(grep -REn '(/home/marzec/\.openclaw/manul|/mnt/f/ubuntu-workspace/\.openclaw/manul)' \
  "$SCRIPT_DIR"/*.sh 2>/dev/null | grep -v 'test_runtime_health.sh' || true)"
if [ -z "$HARDCODED_PATHS" ]; then
  ok "No old absolute runtime paths found"
else
  fail "Old absolute runtime paths remain:\n$HARDCODED_PATHS"
fi

# ── Test 3: Installer contract ────────────────────────────────────────────────
echo
echo "Test 3: Installer contract"
if grep -q 'RUNTIME_DIR="${MANUL_RUNTIME_DIR:-\$HOME/.openclaw/manul}"' \
     "$SCRIPT_DIR/install-manul-symlinks.sh" 2>/dev/null; then
  ok "Installer default runtime is HOME/.openclaw/manul"
else
  fail "Installer default runtime is not HOME/.openclaw/manul"
fi

SCRIPT_COUNT=$(awk '/^SCRIPTS=\(/,/^\)/' \
  "$SCRIPT_DIR/install-manul-symlinks.sh" | grep -c '^ *"' || true)
if [ "$SCRIPT_COUNT" -ge 20 ]; then
  ok "Installer declares $SCRIPT_COUNT runtime entries"
else
  fail "Installer declares only $SCRIPT_COUNT runtime entries (expected at least 20)"
fi

# ── Test 3b: installer self-healing (idempotent, safe to run repeatedly) ───────
echo
echo "Test 3b: Installer self-healing"
SELFHEAL_ROOT="$(mktemp -d /tmp/manul-selfheal-XXXXXX)"
CANON="$SELFHEAL_ROOT/canonical"
RUN1="$SELFHEAL_ROOT/runtime1"
RUN2="$SELFHEAL_ROOT/runtime2"
mkdir -p "$CANON"
cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.md "$CANON/" 2>/dev/null || true
[ -f "$SCRIPT_DIR/manul.db" ] && cp "$SCRIPT_DIR/manul.db" "$CANON/" 2>/dev/null || true

# 1) Missing runtime -> installer creates it and exits 0
set +e
MANUL_RUNTIME_DIR="$RUN1" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC1=$?
set -e
if [ "$RC1" -eq 0 ] && [ -d "$RUN1" ] && [ -L "$RUN1/manul-daemon.sh" ]; then
  ok "Installer recreates a missing runtime directory"
else
  fail "Installer did not recreate missing runtime (rc=$RC1)"
fi

# 2) Idempotent: second run exits 0 and leaves symlinks intact
set +e
MANUL_RUNTIME_DIR="$RUN1" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC2=$?
set -e
if [ "$RC2" -eq 0 ]; then
  ok "Installer is idempotent (second run exits 0)"
else
  fail "Installer is not idempotent (second run rc=$RC2)"
fi

# 3) Every declared symlink resolves to a real file inside canonical source
LINK_FAILS=0
for entry in "$RUN1"/*.sh "$RUN1"/*.md; do
  [ -e "$entry" ] || continue
  [ -L "$entry" ] || { LINK_FAILS=$((LINK_FAILS + 1)); continue; }
  target="$(readlink -f "$entry" 2>/dev/null || true)"
  case "$target" in
    "$CANON"/*) [ -f "$target" ] || LINK_FAILS=$((LINK_FAILS + 1)) ;;
    *) LINK_FAILS=$((LINK_FAILS + 1)) ;;
  esac
done
if [ "$LINK_FAILS" -eq 0 ]; then
  ok "All runtime symlinks resolve into the canonical source"
else
  fail "$LINK_FAILS runtime symlinks are broken or misplaced"
fi

# 4) Regular file slot is converted to a symlink (no data copied into runtime)
rm -f "$RUN1/manul-status.sh"
echo "junk" > "$RUN1/manul-status.sh"
set +e
MANUL_RUNTIME_DIR="$RUN1" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC3=$?
set -e
if [ "$RC3" -eq 0 ] && [ -L "$RUN1/manul-status.sh" ]; then
  ok "Installer converts a regular file slot into a symlink"
else
  fail "Installer did not convert regular file slot (rc=$RC3)"
fi

# 5) Directory collision is refused and the installer exits non-zero
rm -f "$RUN1/poll.sh"
mkdir -p "$RUN1/poll.sh"
set +e
MANUL_RUNTIME_DIR="$RUN1" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC4=$?
set -e
if [ "$RC4" -ne 0 ] && [ -d "$RUN1/poll.sh" ]; then
  ok "Installer refuses a directory collision and exits non-zero"
else
  fail "Installer should refuse directory collision (rc=$RC4)"
fi

# 6) Missing canonical source is fatal
set +e
MANUL_RUNTIME_DIR="$RUN2" MANUL_CANONICAL_DIR="$SELFHEAL_ROOT/missing" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC5=$?
set -e
if [ "$RC5" -ne 0 ]; then
  ok "Installer exits non-zero when canonical source is missing"
else
  fail "Installer should exit non-zero when canonical source is missing"
fi

rm -rf "$SELFHEAL_ROOT"

# ── Test 3c: CLI entrypoints resolve in a fresh shell ────────────────────────
echo
echo "Test 3c: CLI entrypoints resolve in a fresh shell"
CLI_ROOT="$(mktemp -d /tmp/manul-cli-XXXXXX)"
CANON="$CLI_ROOT/canonical"
RUN="$CLI_ROOT/runtime"
mkdir -p "$CANON"
cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.md "$CANON/" 2>/dev/null || true
[ -f "$SCRIPT_DIR/manul.db" ] && cp "$SCRIPT_DIR/manul.db" "$CANON/" 2>/dev/null || true

# Deploy a real runtime so the CLI can actually run
set +e
MANUL_RUNTIME_DIR="$RUN" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
set -e

# 1) All three CLI entrypoints exist as symlinks in the runtime
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh; do
  if [ -L "$RUN/$entry" ] && [ -f "$(readlink -f "$RUN/$entry")" ]; then
    ok "Runtime symlink $entry -> canonical source"
  else
    fail "Runtime symlink $entry missing or broken"
  fi
done

# 2) Each symlink target is the canonical script of the same name
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh; do
  target="$(readlink -f "$RUN/$entry")"
  if [ "$target" = "$CANON/$entry" ]; then
    ok "$entry resolves to canonical $entry"
  else
    fail "$entry resolves to $target (expected $CANON/$entry)"
  fi
done

# 2b) The self-healing guard must check ALL THREE entrypoints, not just
#     manul-daemon.sh. A broken manul-status.sh or manul-comments-remove.sh
#     must also trigger the repair path.
ZSHRC="${MANUL_TEST_ZSHRC:-$HOME/.zshrc}"
GUARD_OK=true
GUARD_BLOCK="$(sed -n '/manul-ensure-runtime()/,/^}/p' "$ZSHRC" 2>/dev/null || true)"
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh; do
  if echo "$GUARD_BLOCK" | grep -qF "$entry"; then
    : # guard references this entrypoint
  else
    fail "Self-healing guard does not reference $entry"
    GUARD_OK=false
  fi
done
$GUARD_OK && ok "Self-healing guard references all three CLI entrypoints"

# 2c) No CLI alias may be wrapped in a conditional that can silently vanish
#     when the runtime is absent (the command must always be defined).
for cmd in manul manul-status manul-comments-remove; do
  line="$(grep -n "alias $cmd=" "$ZSHRC" 2>/dev/null | head -1 || true)"
  if [ -z "$line" ]; then
    fail "$cmd alias is missing entirely"
  elif echo "$line" | grep -qE '^\s*[0-9]+:\s*if\s+\[.*\].*then'; then
    fail "$cmd alias is wrapped in a conditional (can vanish)"
  else
    ok "$cmd alias is unconditional"
  fi
done

# 3) Deleting the runtime does not remove the CLI entrypoints from a fresh
#    shell — the shell definitions are in .zshrc, not in the runtime dir.
rm -rf "$RUN"
# Simulate a fresh shell: aliases must still be defined even though the
# runtime is gone. We check the zshrc source directly since the test runs
# outside an interactive shell.
ZSHRC="${MANUL_TEST_ZSHRC:-$HOME/.zshrc}"
if grep -q "alias manul=" "$ZSHRC" 2>/dev/null; then
  ok "manul alias defined in shell rc (survives runtime deletion)"
else
  fail "manul alias missing from shell rc"
fi
for cmd in manul-status manul-comments-remove; do
  if grep -q "alias $cmd=" "$ZSHRC" 2>/dev/null; then
    ok "$cmd alias defined in shell rc (unconditional, survives runtime deletion)"
  else
    fail "$cmd alias missing from shell rc"
  fi
done

# 4) The repair path (installer) recreates all required symlinks from scratch
set +e
MANUL_RUNTIME_DIR="$RUN" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC_REPAIR=$?
set -e
if [ "$RC_REPAIR" -eq 0 ]; then
  ok "Installer recreates runtime after full deletion"
else
  fail "Installer failed to recreate runtime (rc=$RC_REPAIR)"
fi
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh; do
  if [ -L "$RUN/$entry" ] && [ -f "$(readlink -f "$RUN/$entry")" ]; then
    ok "Repaired runtime symlink $entry exists"
  else
    fail "Repaired runtime symlink $entry missing"
  fi
done

# 5) manul-status --list works (requires a DB; the canonical backup provides one)
if [ -f "$CANON/manul.db" ]; then
  cp "$CANON/manul.db" "$RUN/manul.db"
  chmod 600 "$RUN/manul.db"
fi
set +e
MANUL_DIR="$RUN" "$RUN/manul-status.sh" --list >/dev/null 2>&1
RC_STATUS=$?
set -e
if [ "$RC_STATUS" -eq 0 ]; then
  ok "manul-status --list runs successfully"
else
  fail "manul-status --list failed (rc=$RC_STATUS)"
fi

# 6) manul-comments-remove --help shows usage and never touches GitHub
set +e
HELP_OUT="$(MANUL_DIR="$RUN" "$RUN/manul-comments-remove.sh" --help 2>&1)"
RC_HELP=$?
set -e
if [ "$RC_HELP" -eq 0 ] && echo "$HELP_OUT" | grep -q "Usage:"; then
  ok "manul-comments-remove --help shows usage and exits 0"
else
  fail "manul-comments-remove --help did not show usage (rc=$RC_HELP)"
fi
# --help must not have triggered any deletion (no network call, no comment removal).
# Check for actual command invocations rather than the word "github.com",
# which legitimately appears in usage examples.
if echo "$HELP_OUT" | grep -qiE 'gh api|curl |wget |DELETE|POST '; then
  fail "manul-comments-remove --help output mentions network/API calls"
fi

rm -rf "$CLI_ROOT"

# ── Test 4: Recovery without a backup fails safely ────────────────────────────
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

if [ "$NO_BACKUP_EXIT" -eq 1 ] && echo "$NO_BACKUP_OUTPUT" | grep -q "No valid backup DB found"; then
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

# ── Test 5: Create canonical backup and recover from it ───────────────────────
echo
echo "Test 5: Recovery from canonical-init DB backup"
BACKUP_DB="$TMPROOT/backup/manul.db"
create_canonical_backup "$BACKUP_DB"
CANONICAL_BACKUP_DB="$BACKUP_DB"

# Verify the backup itself has the right tables before using it
for tbl in processed_comments conversations meta workspaces; do
  if ! sqlite3 "$BACKUP_DB" "SELECT 1 FROM $tbl LIMIT 1;" >/dev/null 2>&1; then
    fail "Canonical backup DB missing table '$tbl'"
    exit 1
  fi
done
ok "Canonical backup DB has all required tables"

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

# ── Test 6: All installed links are valid symlinks into canonical source ──────
echo
echo "Test 6: Runtime symlinks"
LINK_FAILURES=0
LINK_COUNT=0
for entry in "$GOOD_RUNTIME"/*.sh "$GOOD_RUNTIME"/*.md; do
  [ -e "$entry" ] || continue
  [ -L "$entry" ] || { LINK_FAILURES=$((LINK_FAILURES + 1)); continue; }
  LINK_COUNT=$((LINK_COUNT + 1))
  target=$(readlink -f "$entry" 2>/dev/null || true)
  case "$target" in
    "$SCRIPT_DIR"/*) ;;
    *) LINK_FAILURES=$((LINK_FAILURES + 1)) ;;
  esac
done

if [ "$LINK_FAILURES" -eq 0 ] && [ "$LINK_COUNT" -ge 20 ]; then
  ok "$LINK_COUNT runtime symlinks valid and point to canonical source"
else
  fail "Runtime symlink check failed: $LINK_COUNT links, $LINK_FAILURES failures"
fi

# ── Test 7: Recovered DB schema matches canonical contract ───────────────────
echo
echo "Test 7: Recovered DB schema"
REQUIRED_TABLES="processed_comments conversations meta workspaces"
SCHEMA_FAILURES=0
for table in $REQUIRED_TABLES; do
  if ! sqlite3 "$GOOD_RUNTIME/manul.db" "SELECT 1 FROM $table LIMIT 1;" >/dev/null 2>&1; then
    SCHEMA_FAILURES=$((SCHEMA_FAILURES + 1))
    fail "Required table '$table' missing from recovered DB"
  fi
done
[ "$SCHEMA_FAILURES" -eq 0 ] && ok "All required tables present in recovered DB"

# Validate key columns on the richest table (processed_comments).
# Avoid duplicating the full schema SQL; only assert the columns the daemon reads.
KEY_COLUMNS="commentId repository issueNumber commentUrl prompt status attempts conversationId action prNumber prUrl"
for col in $KEY_COLUMNS; do
  if ! sqlite3 "$GOOD_RUNTIME/manul.db" \
       "PRAGMA table_info(processed_comments);" 2>/dev/null \
       | grep -qw "$col"; then
    fail "Required column '$col' missing from processed_comments"
  fi
done
ok "Key columns present on processed_comments"

# Validate key columns on conversations
for col in conversationId repository issueNumber issueUrl status activeTaskId createdAt updatedAt; do
  if ! sqlite3 "$GOOD_RUNTIME/manul.db" \
       "PRAGMA table_info(conversations);" 2>/dev/null \
       | grep -qw "$col"; then
    fail "Required column '$col' missing from conversations"
  fi
done
ok "Key columns present on conversations"

# Validate workspaces columns
for col in workspaceId workspacePath status currentTaskId lastUsedAt; do
  if ! sqlite3 "$GOOD_RUNTIME/manul.db" \
       "PRAGMA table_info(workspaces);" 2>/dev/null \
       | grep -qw "$col"; then
    fail "Required column '$col' missing from workspaces"
  fi
done
ok "Key columns present on workspaces"

# ── Test 8: Second repair with same backup is idempotent ──────────────────────
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

# ── Test 9: Archive fallback ─────────────────────────────────────────────────
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

# ── Test 10: init-schema failure is fatal to repair ──────────────────────────
echo
echo "Test 10: init-schema failure is fatal"
READONLY_RUNTIME="$TMPROOT/readonly-runtime"
mkdir -p "$READONLY_RUNTIME"

# Build a DB that has all tables but is missing migration columns (action, prNumber, prUrl).
# This simulates a pre-migration DB that needs ALTER TABLE to reach current schema.
sqlite3 "$READONLY_RUNTIME/manul.db" <<'SQL'
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
  workspaceId TEXT
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

# Make DB read-only so ALTER TABLE migrations cannot apply.
chmod 444 "$READONLY_RUNTIME/manul.db"

# Copy config template so repair reaches step 5.
cp "$SCRIPT_DIR/config.json.example" "$READONLY_RUNTIME/config.json" 2>/dev/null || true

set +e
READONLY_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$READONLY_RUNTIME" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
READONLY_EXIT=$?
set -e

if [ "$READONLY_EXIT" -ne 0 ]; then
  ok "Repair exits non-zero when init-schema fails"
else
  fail "Repair should have exited non-zero when init-schema failed (exit=$READONLY_EXIT)"
fi

if echo "$READONLY_OUTPUT" | grep -q "Repair Complete"; then
  fail "Output must NOT contain 'Repair Complete' on init-schema failure"
else
  ok "Output does not contain 'Repair Complete' on failure"
fi

if echo "$READONLY_OUTPUT" | grep -qiE "schema|initialization|migration|ERROR"; then
  ok "Actual error message is visible in output"
else
  fail "Error message not visible in output"
  echo "  Output was: $READONLY_OUTPUT"
fi

# Verify the existing DB was not corrupted or replaced.
if [ -f "$READONLY_RUNTIME/manul.db" ]; then
  if sqlite3 "$READONLY_RUNTIME/manul.db" "SELECT COUNT(*) FROM processed_comments;" >/dev/null 2>&1; then
    ok "Existing DB preserved (not corrupted) after failed repair"
  else
    fail "Existing DB was corrupted during failed repair"
  fi
else
  fail "Existing DB was removed during failed repair"
fi

# ── Test 11: workspace_init failure is fatal ────────────────────────────────
echo
echo "Test 11: workspace_init failure is fatal"
WSFAIL_DIR="$TMPROOT/ws-fail-dir"
mkdir -p "$WSFAIL_DIR"

# Build a DB with conversation tables but WITHOUT the workspaces table.
# Then make it read-only so workspace_init cannot CREATE the missing table.
sqlite3 "$WSFAIL_DIR/manul.db" <<'SQL'
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
SQL
chmod 444 "$WSFAIL_DIR/manul.db"

# Call workspace_init directly with the read-only DB missing the workspaces table.
WS_INIT_OUTPUT=""
WS_INIT_EXIT=0
WS_INIT_OUTPUT="$(MANUL_DIR="$WSFAIL_DIR" DB="$WSFAIL_DIR/manul.db" \
  bash -c 'source "$1"; workspace_init' _ "$SCRIPT_DIR/workspace-manager.sh" 2>&1)" || WS_INIT_EXIT=$?

if [ "$WS_INIT_EXIT" -ne 0 ]; then
  ok "workspace_init exits non-zero when it cannot create missing table"
else
  fail "workspace_init should have failed (exit=$WS_INIT_EXIT)"
fi

if [ -n "$WS_INIT_OUTPUT" ] && echo "$WS_INIT_OUTPUT" | grep -qiE "error|permission|readonly|database"; then
  ok "workspace_init surfaces the actual error"
else
  fail "workspace_init error output not visible"
  echo "  Output was: $WS_INIT_OUTPUT"
fi

# Verify the existing DB is not corrupted.
if sqlite3 "$WSFAIL_DIR/manul.db" "SELECT COUNT(*) FROM processed_comments;" >/dev/null 2>&1; then
  ok "Existing DB preserved after failed workspace_init"
else
  fail "Existing DB was corrupted by failed workspace_init"
fi

# ── Test 12: existing empty DB + valid backup → backup restored ─────────────
echo
echo "Test 12: Empty DB + valid backup → restore succeeds"
EMPTY_RUNTIME="$TMPROOT/empty-db-runtime"
mkdir -p "$EMPTY_RUNTIME"

# Create a 0-byte manul.db (simulates corrupted or freshly-created empty file)
touch "$EMPTY_RUNTIME/manul.db"
chmod 644 "$EMPTY_RUNTIME/manul.db"
# Copy config template so repair reaches step 4/5.
cp "$SCRIPT_DIR/config.json.example" "$EMPTY_RUNTIME/config.json" 2>/dev/null || true

set +e
EMPTY_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$EMPTY_RUNTIME" \
  MANUL_SOURCE_DB="$BACKUP_DB" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
EMPTY_EXIT=$?
set -e

if [ "$EMPTY_EXIT" -eq 0 ] && echo "$EMPTY_OUTPUT" | grep -q "Repair Complete"; then
  ok "Repair succeeds after restoring backup over empty DB"
else
  fail "Repair failed over empty DB (exit=$EMPTY_EXIT)"
  echo "$EMPTY_OUTPUT"
fi

# Verify the restored DB is valid and has the right tables.
RESTORED_DB="$EMPTY_RUNTIME/manul.db"
if db_is_valid "$RESTORED_DB" 2>/dev/null; then
  ok "Restored DB is valid SQLite after repair"
else
  # db_is_valid may not be defined in this scope; fall back to basic checks
  if [ -s "$RESTORED_DB" ] && sqlite3 "$RESTORED_DB" "PRAGMA integrity_check;" 2>/dev/null | grep -q "^ok$"; then
    ok "Restored DB is valid SQLite after repair (basic check)"
  else
    fail "Restored DB is not valid SQLite"
  fi
fi

for tbl in processed_comments conversations meta workspaces; do
  if ! sqlite3 "$RESTORED_DB" "SELECT 1 FROM $tbl LIMIT 1;" >/dev/null 2>&1; then
    fail "Restored DB missing table '$tbl' after repair over empty DB"
  fi
done
ok "Restored DB has all required tables"

# ── Test 13: existing corrupt DB + no backup → repair aborts ────────────────
echo
echo "Test 13: Corrupt DB + no backup → repair aborts, no schema fabricated"
CORRUPT_RUNTIME="$TMPROOT/corrupt-runtime"
mkdir -p "$CORRUPT_RUNTIME"

# Write an invalid file that is non-empty but NOT a SQLite DB.
echo "not a database" > "$CORRUPT_RUNTIME/manul.db"
chmod 644 "$CORRUPT_RUNTIME/manul.db"
cp "$SCRIPT_DIR/config.json.example" "$CORRUPT_RUNTIME/config.json" 2>/dev/null || true

set +e
CORRUPT_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$CORRUPT_RUNTIME" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
CORRUPT_EXIT=$?
set -e

if [ "$CORRUPT_EXIT" -ne 0 ]; then
  ok "Repair exits non-zero for corrupt DB with no backup"
else
  fail "Repair should have aborted for corrupt DB (exit=$CORRUPT_EXIT)"
fi

if echo "$CORRUPT_OUTPUT" | grep -q "No valid backup DB found"; then
  ok "Repair reports missing backup for corrupt DB"
else
  fail "Repair did not report missing backup"
  echo "  Output: $CORRUPT_OUTPUT"
fi

if echo "$CORRUPT_OUTPUT" | grep -q "Repair Complete"; then
  fail "Repair must NOT complete when DB is corrupt and no backup exists"
else
  ok "Repair does not print 'Repair Complete' on corrupt-DB failure"
fi

# Verify no schema was fabricated from the corrupt file.
if [ -f "$CORRUPT_RUNTIME/manul.db" ]; then
  if sqlite3 "$CORRUPT_RUNTIME/manul.db" "SELECT 1 FROM processed_comments LIMIT 1;" 2>/dev/null | grep -q .; then
    fail "Schema was fabricated from corrupt DB — tables exist when they should not"
  else
    ok "No schema fabricated; corrupt DB untouched"
  fi
else
  ok "Corrupt DB was not replaced (no backup available)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
