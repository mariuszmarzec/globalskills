#!/bin/bash
# repair-manul-runtime.sh — Repair Manul runtime directory
#
# Usage:
#   repair-manul-runtime.sh [--runtime-dir <path>] [--source-db <path>]
#
# This script repairs a broken or missing Manul runtime directory by:
# 1. Creating the runtime directory
# 2. Deploying symlinks to canonical scripts
# 3. Restoring config.json from template if missing
# 4. Restoring or initializing manul.db (requires backup source)
#
# If no backup DB is available, the script exits with an error rather
# than creating an incomplete schema that would cause runtime failures.

set -euo pipefail

RUNTIME_DIR="${MANUL_RUNTIME_DIR:-$HOME/.openclaw/manul}"
SOURCE_DB="${MANUL_SOURCE_DB:-}"
CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"

echo "=== Manul Runtime Repair ==="
echo "Runtime:    $RUNTIME_DIR"
echo "Canonical:  $CANONICAL_DIR"
echo ""

# Step 1: Create runtime directory
if [ ! -d "$RUNTIME_DIR" ]; then
    echo "[1/5] Creating runtime directory: $RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
else
    echo "[1/5] Runtime directory exists: $RUNTIME_DIR"
fi

# Step 2: Deploy symlinks
echo ""
echo "[2/5] Deploying symlinks..."
"$CANONICAL_DIR/install-manul-symlinks.sh" --runtime-dir "$RUNTIME_DIR"

# Step 3: Restore config if missing
if [ ! -f "$RUNTIME_DIR/config.json" ]; then
    echo ""
    echo "[3/5] Config not found, checking for template..."
    if [ -f "$CANONICAL_DIR/config.json.example" ]; then
        cp "$CANONICAL_DIR/config.json.example" "$RUNTIME_DIR/config.json"
        echo "  Copied config.json.example -> config.json"
        echo "  WARNING: Edit $RUNTIME_DIR/config.json before starting daemon"
    else
        echo "  WARNING: No config.json.example found in canonical dir"
    fi
else
    echo ""
    echo "[3/5] Config exists: $RUNTIME_DIR/config.json"
fi

# Step 4: Restore DB from backup if possible
DB_FILE="$RUNTIME_DIR/manul.db"
if [ -f "$DB_FILE" ]; then
    echo ""
    echo "[4/5] DB exists: $DB_FILE"
else
    echo ""
    echo "[4/5] DB not found, attempting restore..."
    RESTORED=false

    # Prefer explicit --source-db
    if [ -n "$SOURCE_DB" ] && [ -f "$SOURCE_DB" ]; then
        cp "$SOURCE_DB" "$DB_FILE"
        RESTORED=true
        echo "  Restored DB from: $SOURCE_DB"
    # Fallback: check archive directories
    elif [ -d "$RUNTIME_DIR-archive-"*".db" ] 2>/dev/null; then
        LATEST_BAK=$(ls -t "$RUNTIME_DIR-archive-"*.db 2>/dev/null | head -1)
        if [ -n "$LATEST_BAK" ]; then
            cp "$LATEST_BAK" "$DB_FILE"
            RESTORED=true
            echo "  Restored DB from archive: $LATEST_BAK"
        fi
    fi

    if [ "$RESTORED" = false ]; then
        echo ""
        echo "  ERROR: No backup DB found."
        echo "  To restore from a backup, run:"
        echo "    MANUL_SOURCE_DB=/path/to/backup/manul.db $0"
        echo ""
        echo "  Alternatively, copy the DB from the legacy runtime:"
        echo "    cp /mnt/f/ubuntu-workspace/.openclaw/manul/manul.db $DB_FILE"
        echo ""
        echo "  Recovery aborted. A valid manul.db is required for the daemon to start."
        exit 1
    fi
fi

# Step 5: Ensure DB schema is complete by sourcing canonical init functions
echo ""
echo "[5/5] Validating DB schema..."
export MANUL_DIR="$RUNTIME_DIR"
export DB="$DB_FILE"

# Source init_schema from manul-conversation.sh (idempotent, CREATE IF NOT EXISTS)
if [ -f "$CANONICAL_DIR/manul-conversation.sh" ]; then
    # Extract and run only the init_schema function to avoid side effects
    bash -c "
        MANUL_DIR='$RUNTIME_DIR'
        DB='$DB_FILE'
        $(grep -A 80 '^init_schema()' '$CANONICAL_DIR/manul-conversation.sh' | head -60)
    " 2>/dev/null || true
    echo "  Schema validated via manul-conversation.sh init_schema"
fi

# Source workspace_init from workspace-manager.sh
if [ -f "$CANONICAL_DIR/workspace-manager.sh" ]; then
    bash -c "
        MANUL_DIR='$RUNTIME_DIR'
        DB='$DB_FILE'
        $(grep -A 10 '^workspace_init()' '$CANONICAL_DIR/workspace-manager.sh')
    " 2>/dev/null || true
    echo "  Workspace table validated via workspace-manager.sh workspace_init"
fi

# Verify required tables exist
REQUIRED_TABLES="processed_comments meta workspaces"
MISSING_TABLES=""
for tbl in $REQUIRED_TABLES; do
    if ! sqlite3 "$DB_FILE" "SELECT 1 FROM $tbl LIMIT 1;" >/dev/null 2>&1; then
        MISSING_TABLES="$MISSING_TABLES $tbl"
    fi
done

if [ -n "$MISSING_TABLES" ]; then
    echo "  WARNING: Missing tables:$MISSING_TABLES"
    echo "  The daemon may not function correctly without these tables."
    echo "  Restore from a backup DB to fix."
    exit 1
fi

echo "  All required tables present."

echo ""
echo "=== Repair Complete ==="
echo "Start daemon with:"
echo "  setsid $RUNTIME_DIR/manul-daemon.sh start >/dev/null 2>&1 &"
echo ""
echo "Or use the automation wrapper:"
echo "  $RUNTIME_DIR/start-manul-automation.sh start"
