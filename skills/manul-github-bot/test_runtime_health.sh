#!/bin/bash
# test_runtime_health.sh — Regression tests for Manul runtime health
#
# Tests that verify:
# 1. No hardcoded absolute paths in scripts (should use $MANUL_DIR)
# 2. Runtime directory exists and is recoverable
# 3. Symlinks are valid
# 4. DB and config are accessible

set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CANONICAL_DIR="${CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"
PASS=0
FAIL=0

cleanup() {
  # Nothing to clean up - we only verify
  :
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

# Test 1: Check for hardcoded absolute paths in scripts
echo "Test 1: No hardcoded absolute paths in shell scripts"
HARDCODED_PATHS=$(grep -rn '"/home/marzec/.openclaw/manul\|"/mnt/f/ubuntu-workspace/.openclaw/manul' \
  "$CANONICAL_DIR"/*.sh 2>/dev/null | grep -v "test_runtime_health.sh" || true)
if [ -z "$HARDCODED_PATHS" ]; then
  ok "No hardcoded /home/marzec/.openclaw/manul paths found"
else
  fail "Found hardcoded paths:\n$HARDCODED_PATHS"
fi

# Test 2: Runtime directory exists or is recoverable
echo ""
echo "Test 2: Runtime directory accessibility"
if [ -d "$MANUL_DIR" ]; then
  ok "Runtime directory exists: $MANUL_DIR"
else
  fail "Runtime directory missing: $MANUL_DIR"
fi

# Test 3: Symlinks are valid
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

# Test 4: DB accessible
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

# Test 5: Config accessible
echo ""
echo "Test 5: Config accessibility"
CONFIG="${MANUL_DIR}/config.json"
if [ -f "$CONFIG" ]; then
  REPOS=$(jq -r '.repositories | length' "$CONFIG" 2>/dev/null || echo "0")
  ok "Config accessible, repositories: $REPOS"
else
  fail "Config not found: $CONFIG"
fi

# Test 6: MANUL_DIR variable propagation
echo ""
echo "Test 6: Scripts use MANUL_DIR variable (not hardcoded)"
USING_MANUL_DIR=true
for script in watchdog.sh task-recovery.sh github-api-wrapper.sh task-health-check.sh manul-conversation.sh; do
  FILE="$CANONICAL_DIR/$script"
  [ -f "$FILE" ] || continue
  
  # Check if script sets MANUL_DIR
  if ! grep -q 'MANUL_DIR=' "$FILE" 2>/dev/null; then
    fail "$script does not set MANUL_DIR"
    USING_MANUL_DIR=false
  fi
  
  # Check if script uses ${MANUL_DIR} for DB/PID paths
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

# Summary
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
