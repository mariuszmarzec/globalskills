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
# 4. Restoring manul.db from an existing backup
# 5. Validating/upgrading the DB using the canonical Manul init routines
#
# The repair script never invents a new application schema. A missing DB must
# be restored from an explicit backup or a previously-created runtime archive.

set -euo pipefail

RUNTIME_DIR="${MANUL_RUNTIME_DIR:-$HOME/.openclaw/manul}"
SOURCE_DB="${MANUL_SOURCE_DB:-}"
CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

if [ ! -d "$CANONICAL_DIR" ]; then
    fail "Canonical Manul directory does not exist: $CANONICAL_DIR"
fi

if [ ! -x "$CANONICAL_DIR/install-manul-symlinks.sh" ]; then
    fail "Missing or non-executable install-manul-symlinks.sh in $CANONICAL_DIR"
fi

printf '%s\n' "=== Manul Runtime Repair ==="
printf 'Runtime:    %s\n' "$RUNTIME_DIR"
printf 'Canonical:  %s\n\n' "$CANONICAL_DIR"

# Step 1: Create runtime directory.
if [ ! -d "$RUNTIME_DIR" ]; then
    echo "[1/5] Creating runtime directory: $RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
else
    echo "[1/5] Runtime directory exists: $RUNTIME_DIR"
fi

# Step 2: Deploy all runtime symlinks from the canonical source.
echo
"[2/5]" # keep progress marker stable for logs
printf '%s\n' "[2/5] Deploying symlinks..."
"$CANONICAL_DIR/install-manul-symlinks.sh" --runtime-dir "$RUNTIME_DIR"

# Step 3: Restore config if missing. Existing config is never overwritten.
if [ ! -f "$RUNTIME_DIR/config.json" ]; then
    echo
    echo "[3/5] Config not found, restoring template..."
    if [ -f "$CANONICAL_DIR/config.json.example" ]; then
        cp "$CANONICAL_DIR/config.json.example" "$RUNTIME_DIR/config.json"
        echo "  Copied config.json.example -> config.json"
        echo "  WARNING: Edit $RUNTIME_DIR/config.json before starting daemon"
    else
        fail "No config.json and no config.json.example found in $CANONICAL_DIR"
    fi
else
    echo
    echo "[3/5] Config exists: $RUNTIME_DIR/config.json"
fi

# Validate config before touching/starting the daemon.
if ! jq empty "$RUNTIME_DIR/config.json" >/dev/null 2>&1; then
    fail "Invalid JSON in $RUNTIME_DIR/config.json"
fi

# Step 4: Restore an existing DB. Never fabricate an incomplete schema.
DB_FILE="$RUNTIME_DIR/manul.db"
if [ -f "$DB_FILE" ]; then
    echo
    echo "[4/5] DB exists: $DB_FILE"
else
    echo
    echo "[4/5] DB not found, attempting restore..."
    RESTORED=false

    if [ -n "$SOURCE_DB" ]; then
        if [ ! -f "$SOURCE_DB" ]; then
            fail "MANUL_SOURCE_DB does not point to a file: $SOURCE_DB"
        fi
        cp "$SOURCE_DB" "$DB_FILE"
        RESTORED=true
        echo "  Restored DB from: $SOURCE_DB"
    else
        # Look for the newest archived runtime sibling, e.g.
        # ~/.openclaw/manul-archive-20260916-123456/manul.db
        ARCHIVE_ROOT="$(dirname "$RUNTIME_DIR")"
        ARCHIVE_PREFIX="$(basename "$RUNTIME_DIR")-archive-"
        LATEST_BAK=""
        if [ -d "$ARCHIVE_ROOT" ]; then
            while IFS= read -r -d '' archive_dir; do
                candidate="$archive_dir/manul.db"
                if [ -f "$candidate" ]; then
                    LATEST_BAK="$candidate"
                    break
                fi
            done < <(find "$ARCHIVE_ROOT" -maxdepth 1 -mindepth 1 -type d -name "${ARCHIVE_PREFIX}*" -printf '%T@ %p\0' 2>/dev/null | sort -z -nr | sed -z 's/^[^ ]* //')
        fi

        if [ -n "$LATEST_BAK" ]; then
            cp "$LATEST_BAK" "$DB_FILE"
            RESTORED=true
            echo "  Restored DB from archive: $LATEST_BAK"
        fi
    fi

    if [ "$RESTORED" = false ]; then
        echo
        echo "ERROR: No backup DB found."
        echo "To restore from a backup, run:"
        echo "  MANUL_SOURCE_DB=/path/to/backup/manul.db $0"
        echo ""
        echo "Recovery aborted. A valid manul.db is required; no new application schema will be fabricated."
        exit 1
    fi
fi

# Step 5: Run the canonical DB initialization/migration routines.
# manul-conversation.sh already owns init_schema(). Invoke it through its public
# CLI instead of duplicating or scraping its implementation. A deliberately
# missing conversation is expected to return exit code 2 after init_schema runs.
echo
echo "[5/5] Validating DB schema..."

CONV_OUTPUT=""
CONV_EXIT=0
CONV_OUTPUT="$(MANUL_DIR="$RUNTIME_DIR" "$RUNTIME_DIR/manul-conversation.sh" status --conversation-id "__runtime_repair_schema_check__" --json 2>&1)" || CONV_EXIT=$?

if [ "$CONV_EXIT" -ne 0 ] && [ "$CONV_EXIT" -ne 2 ]; then
    printf '%s\n' "$CONV_OUTPUT" >&2
    fail "Canonical manul-conversation schema initialization failed (exit $CONV_EXIT)"
fi

echo "  Canonical conversation schema validated."

# workspace-manager.sh only defines functions, so sourcing it and calling the
# canonical workspace_init() is side-effect-safe and avoids duplicating schema.
WORKSPACE_OUTPUT=""
WORKSPACE_EXIT=0
WORKSPACE_OUTPUT="$(MANUL_DIR="$RUNTIME_DIR" DB="$DB_FILE" bash -c 'source "$1" && workspace_init' _ "$CANONICAL_DIR/workspace-manager.sh" 2>&1)" || WORKSPACE_EXIT=$?
if [ "$WORKSPACE_EXIT" -ne 0 ]; then
    printf '%s\n' "$WORKSPACE_OUTPUT" >&2
    fail "Canonical workspace initialization failed (exit $WORKSPACE_EXIT)"
fi

echo "  Canonical workspace schema validated."

# Final smoke check for required tables.
REQUIRED_TABLES="processed_comments conversations meta workspaces"
for table in $REQUIRED_TABLES; do
    if ! sqlite3 "$DB_FILE" "SELECT 1 FROM $table LIMIT 1;" >/dev/null 2>&1; then
        fail "Required table '$table' is missing from $DB_FILE"
    fi
done

echo "  Required tables present: $REQUIRED_TABLES"
echo
echo "=== Repair Complete ==="
echo "Start daemon with:"
echo "  setsid $RUNTIME_DIR/manul-daemon.sh start >/dev/null 2>&1 &"
echo
echo "Or use the automation wrapper:"
echo "  $RUNTIME_DIR/start-manul-automation.sh start"
