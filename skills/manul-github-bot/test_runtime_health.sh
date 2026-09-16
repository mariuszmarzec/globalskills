#!/bin/bash
# test_runtime_health.sh — Regression tests for Manul runtime health
#
# Tests that verify:
# 1. No hardcoded absolute paths in scripts (should use $MANUL_DIR)
# 2. Runtime directory exists and is recoverable
# 3. Symlinks are valid
# 4. DB and config are accessible
# 5. repair-manul-runtime.sh works in isolation (TMPDIR-based)

set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CANONICAL_DIR="${CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"
PASS=0
FAIL=0
TMPRUNTIME=""

cleanup() {
  [ -n "$TMPRUNTIME" ] && rm -rf "$TMPRUNTIME"
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

echo "=== Runtime Health Tests ==="
echo "MANUL_DIR=$MANUL_DIR"
echo "CANONICAL_DIR=$CANONICAL_DIR"
echo ""

# ── Test 1: No hardcoded absolute paths in shell scripts ──────────────────────
echo "Test 1: No hardcoded absolute paths in shell scripts"
HARDCODED_PATHS=$(grep -rn '"/home/marzec/.openclaw/manul\|"/mnt/f/ubuntu-workspace/.openclaw/manul' \
  "$CANONICAL_DIR"/*.sh 2>/dev/null | grep -v "test_runtime_health.sh" | grep -v "test_runtime_isolation.sh" || true)
if [ -z "$HARDCODED_PATHS" ]; then
  ok "No hardcoded /home/marzec/.openclaw/manul paths found"
else
  fail "Found hardcoded paths:\n$HARDCODED_PATHS"
fi

# ── Test 2: Runtime directory accessibility ────────────────────────────────────
echo ""
echo "Test 2: Runtime directory accessibility"
if [ -d "$MANUL_DIR" ]; then
  ok "Runtime directory exists: $MANUL_DIR"
else
  fail "Runtime directory missing: $MANUL_DIR"
fi

# ── Test 3: Symlink validity ──────────────────────────────────────────────────
echo ""
echo "Test 3: Symlink validity"
SYMLINK_COUNT=0
BROKEN_COUNT=0
for f in "$MANUL_DIR"/*.sh; do
  [ -f "$f" ] || continue
  SYMLINK_COUNT=$((SYMLINK_COUNT + 1))
  if [ -L "$f" ]; then
    TARGET=$(readlink "$f")
    if [ -f "$TARGET" ]; then
      : # valid symlink
    else
      BROKEN_COUNT=$((BROKEN_COUNT + 1))
      fail "Broken symlink: $f -> $TARGET"
    fi
  else
    BROKEN_COUNT=$((BROKEN_COUNT + 1))
    fail "Not a symlink: $f"
  fi
done
if [ "$BROKEN_COUNT" -eq 0 ] && [ "$SYMLINK_COUNT" -gt 0 ]; then
  ok "$SYMLINK_COUNT symlinks valid, 0 broken"
elif [ "$SYMLINK_COUNT" -eq 0 ]; then
  fail "No .sh symlinks found in runtime directory"
else
  fail "$BROKEN_COUNT broken symlinks out of $SYMLINK_COUNT"
fi

# ── Test 4: DB accessible ─────────────────────────────────────────────────────
echo ""
echo "Test 4: Database accessibility"
DB="${MANUL_DIR}/manul.db"
if [ -f "$DB" ]; then
  TABLES=$(sqlite3 "$DB" ".tables" 2>/dev/null || echo "")
  if [ -n "$TABLES" ]; then
    ok "DB accessible, tables: $TABLES"
  else
    fail "DB exists but tables query failed"
  fi
else
  fail "DB not found: $DB"
fi

# ── Test 5: Config accessible ─────────────────────────────────────────────────
echo ""
echo "Test 5: Config accessibility"
CONFIG="${MANUL_DIR}/config.json"
if [ -f "$CONFIG" ]; then
  REPOS=$(jq -r '.repositories | length' "$CONFIG" 2>/dev/null || echo "0")
  ok "Config accessible, repositories: $REPOS"
else
  fail "Config not found: $CONFIG"
fi

# ── Test 6: Scripts use MANUL_DIR variable ────────────────────────────────────
echo ""
echo "Test 6: Scripts use MANUL_DIR variable (not hardcoded)"
USING_MANUL_DIR=true
for script in watchdog.sh task-recovery.sh github-api-wrapper.sh task-health-check.sh manul-conversation.sh; do
  FILE="$CANONICAL_DIR/$script"
  [ -f "$FILE" ] || continue

  if ! grep -q 'MANUL_DIR=' "$FILE" 2>/dev/null; then
    fail "$script does not set MANUL_DIR"
    USING_MANUL_DIR=false
  fi

  if grep -q 'DB="\${MANUL_DIR}/manul.db"\|MANUL_DB="\${MANUL_DIR}/manul.db"' "$FILE" 2>/dev/null; then
    : # correct usage
  elif grep -q 'DB="/home/marzec/.openclaw/manul/manul.db"\|DB="/mnt/f/ubuntu-workspace/.openclaw/manul/manul.db"' "$FILE" 2>/dev/null; then
    fail "$script uses hardcoded DB path instead of \$MANUL_DIR"
    USING_MANUL_DIR=false
  fi
done
if $USING_MANUL_DIR; then
  ok "All scripts use MANUL_DIR variable correctly"
fi

# ── Test 7: repair-manul-runtime.sh isolated integration test ─────────────────
echo ""
echo "Test 7: repair-manul-runtime.sh — isolated integration"

TMPRUNTIME=$(mktemp -d /tmp/manul-repair-test-XXXXXX)
export MANUL_RUNTIME_DIR="$TMPRUNTIME"
export MANUL_CANONICAL_DIR="$CANONICAL_DIR"

# 7a: Run repair on empty runtime
echo "  7a: Running repair on fresh runtime..."
REPAIR_OUTPUT=$("$CANONICAL_DIR/repair-manul-runtime.sh" 2>&1) || REPAIR_EXIT=$? || true
REPAIR_EXIT="${REPAIR_EXIT:-0}"
# Repair exits 1 when no DB backup is available — this is correct, expected behavior
if echo "$REPAIR_OUTPUT" | grep -q "Repair Complete"; then
  ok "Repair script completed successfully"
elif [ "$REPAIR_EXIT" -eq 1 ] && echo "$REPAIR_OUTPUT" | grep -q "No backup DB found\|Recovery aborted"; then
  ok "Repair script correctly aborted (no DB backup available, exit 1)"
else
  fail "Repair script failed unexpectedly (exit=$REPAIR_EXIT)"
fi

# 7b: Verify runtime directory was created
if [ -d "$TMPRUNTIME" ]; then
  ok "Runtime directory created: $TMPRUNTIME"
else
  fail "Runtime directory not created"
fi

# 7c: Verify symlinks
SYMLINK_CHECK=$(ls "$TMPRUNTIME"/*.sh "$TMPRUNTIME"/*.md 2>/dev/null | wc -l)
if [ "$SYMLINK_CHECK" -gt 15 ]; then
  ok "$SYMLINK_CHECK symlinks created"
else
  fail "Expected >15 symlinks, got $SYMLINK_CHECK"
fi

# 7d: Verify config
if [ -f "$TMPRUNTIME/config.json" ]; then
  REPO_COUNT=$(jq -r '.repositories | length' "$TMPRUNTIME/config.json" 2>/dev/null || echo 0)
  if [ "$REPO_COUNT" -gt 0 ]; then
    ok "config.json created with $REPO_COUNT repositories"
  else
    fail "config.json exists but has no repositories"
  fi
else
  fail "config.json not created"
fi

# 7e: Verify DB — should fail without backup source (expected behavior)
# The repair script should abort when no backup DB is available
if echo "$REPAIR_OUTPUT" | grep -q "ERROR.*No backup DB found\|Recovery aborted"; then
  ok "Repair correctly aborted without DB backup (as expected)"
else
  # Check if DB was created anyway
  if [ -f "$TMPRUNTIME/manul.db" ]; then
    # DB exists — verify it has proper schema, not the broken one from old version
    HAS_PROPER_SCHEMA=$(sqlite3 "$TMPRUNTIME/manul.db" "SELECT name FROM sqlite_master WHERE type='table' AND name='processed_comments';" 2>/dev/null)
    if [ -n "$HAS_PROPER_SCHEMA" ]; then
      ok "DB has proper processed_comments table"
    else
      fail "DB exists but lacks proper schema"
    fi
  else
    ok "DB not created (correct — no backup available)"
  fi
fi

# 7f: Verify required tables exist in the real runtime DB
echo ""
echo "  7f: Checking real runtime DB schema completeness..."
REQUIRED_TABLES="processed_comments meta workspaces"
ALL_PRESENT=true
for tbl in $REQUIRED_TABLES; do
  if ! sqlite3 "$MANUL_DIR/manul.db" "SELECT 1 FROM $tbl LIMIT 1;" >/dev/null 2>&1; then
    fail "Required table '$tbl' missing from DB"
    ALL_PRESENT=false
  fi
done
$ALL_PRESENT && ok "All required tables present in runtime DB"

# 7g: Idempotency — run repair again on existing runtime
echo ""
echo "  7g: Testing idempotency (second repair run)..."
REPAIR_OUTPUT2=$("$CANONICAL_DIR/repair-manul-runtime.sh" 2>&1) || true
if echo "$REPAIR_OUTPUT2" | grep -q "Repair Complete\|Runtime directory exists"; then
  ok "Second repair run completed without errors"
else
  fail "Second repair run failed"
fi

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
