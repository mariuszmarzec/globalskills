#!/bin/bash
# repair-manul-runtime.sh — Repair Manul runtime directory
#
# Usage:
#   repair-manul-runtime.sh [--runtime-dir <path>] [--source-db <path>]
#
# This script repairs a broken or missing Manul runtime directory by:
# 1. Creating the runtime directory
# 2. Deploying symlinks to canonical scripts
# 3. Optionally restoring config.json and manul.db from source

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
    echo "[1/4] Creating runtime directory: $RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
else
    echo "[1/4] Runtime directory exists: $RUNTIME_DIR"
fi

# Step 2: Deploy symlinks
echo ""
echo "[2/4] Deploying symlinks..."
"$CANONICAL_DIR/install-manul-symlinks.sh" --runtime-dir "$RUNTIME_DIR"

# Step 3: Restore config if missing
if [ ! -f "$RUNTIME_DIR/config.json" ]; then
    echo ""
    echo "[3/4] Config not found, checking for template..."
    if [ -f "$CANONICAL_DIR/config.json.example" ]; then
        cp "$CANONICAL_DIR/config.json.example" "$RUNTIME_DIR/config.json"
        echo "  Copied config.json.example -> config.json"
        echo "  WARNING: Edit $RUNTIME_DIR/config.json before starting daemon"
    else
        echo "  WARNING: No config.json.example found in canonical dir"
    fi
else
    echo ""
    echo "[3/4] Config exists: $RUNTIME_DIR/config.json"
fi

# Step 4: Restore DB if requested or missing
if [ ! -f "$RUNTIME_DIR/manul.db" ]; then
    echo ""
    echo "[4/4] DB not found, attempting restore..."
    if [ -n "$SOURCE_DB" ] && [ -f "$SOURCE_DB" ]; then
        cp "$SOURCE_DB" "$RUNTIME_DIR/manul.db"
        echo "  Restored DB from: $SOURCE_DB"
    elif [ -f "${RUNTIME_DIR}.bak/manul.db" ]; then
        cp "${RUNTIME_DIR}.bak/manul.db" "$RUNTIME_DIR/manul.db"
        echo "  Restored DB from backup"
    else
        echo "  Creating fresh DB schema..."
        sqlite3 "$RUNTIME_DIR/manul.db" "
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS processed_comments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                commentId TEXT UNIQUE,
                repository TEXT,
                issueNumber INTEGER,
                status TEXT DEFAULT 'queued',
                attempt INTEGER DEFAULT 0,
                createdAt TEXT DEFAULT (datetime('now')),
                updatedAt TEXT DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS workspaces (
                id TEXT PRIMARY KEY,
                task_id TEXT,
                pid INTEGER,
                created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS submission_claims (
                id TEXT PRIMARY KEY,
                repo TEXT,
                branch TEXT,
                pr_number INTEGER,
                claimed_at TEXT DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS ci_fix_failed (
                id TEXT PRIMARY KEY,
                repo TEXT,
                issue_number INTEGER,
                error TEXT,
                fixed_at TEXT
            );
            CREATE TABLE IF NOT EXISTS ci_fix_seen (
                id TEXT PRIMARY KEY,
                repo TEXT,
                issue_number INTEGER,
                seen_at TEXT
            );
        "
        echo "  Created fresh DB at: $RUNTIME_DIR/manul.db"
    fi
else
    echo ""
    echo "[4/4] DB exists: $RUNTIME_DIR/manul.db"
fi

echo ""
echo "=== Repair Complete ==="
echo "Start daemon with:"
echo "  setsid $RUNTIME_DIR/manul-daemon.sh start >/dev/null 2>&1 &"
echo ""
echo "Or use the automation wrapper:"
echo "  $RUNTIME_DIR/start-manul-automation.sh start"
