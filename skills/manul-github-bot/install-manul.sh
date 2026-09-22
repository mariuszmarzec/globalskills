#!/bin/bash
# install-manul.sh — Canonical Manul installer
#
# Idempotent one-shot bootstrap of a fresh Manul runtime:
#   1. Self-detect canonical source
#   2. Validate canonical source
#   3. Ensure runtime directory
#   4. Deploy symlinks via install-manul-symlinks.sh
#   5. Restore config.json from example if missing
#   6. Bootstrap/migrate manul.db (create+init if missing; replace with a fresh
#      DB if schema initialization fails)
#   7. Install the dormant watchdog cron (it only acts when .enabled exists)
#   8. Install canonical zsh shell integration
#   9. Verify and print summary
#
# This installer does NOT start the daemon and does NOT create the .enabled
# marker. The watchdog cron may exist after installation, but it exits
# immediately until .enabled is present.
#
# Usage:
#   install-manul.sh [--runtime-dir <path>] [--canonical-dir <path>]
#
# Environment overrides:
#   MANUL_RUNTIME_DIR    Runtime directory (default: ~/.openclaw/manul)
#   MANUL_CANONICAL_DIR  Canonical skill directory (default: this script's dir)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$SCRIPT_DIR}"
RUNTIME_DIR="${MANUL_RUNTIME_DIR:-$HOME/.openclaw/manul}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Parse CLI flags (env vars take priority; flags override defaults only)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime-dir) RUNTIME_DIR="$2"; shift 2 ;;
        --canonical-dir) CANONICAL_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--runtime-dir <path>] [--canonical-dir <path>]"
            echo ""
            echo "Environment overrides:"
            echo "  MANUL_RUNTIME_DIR    Runtime directory"
            echo "  MANUL_CANONICAL_DIR  Canonical skill directory"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--runtime-dir <path>] [--canonical-dir <path>]" >&2
            exit 1
            ;;
    esac
done

# 1. Self-detect / validate canonical source
if [ ! -d "$CANONICAL_DIR" ]; then
    fail "Canonical Manul directory does not exist: $CANONICAL_DIR"
fi
CANONICAL_DIR="$(cd "$CANONICAL_DIR" && pwd)"

for required in install-manul-symlinks.sh config.json.example \
             manul-conversation.sh workspace-manager.sh watchdog.sh \
             manul-shell.zsh manul-daemon.sh manul-status.sh; do
    if [ ! -f "$CANONICAL_DIR/$required" ]; then
        fail "Missing required canonical file: $CANONICAL_DIR/$required"
    fi
done

echo "=== Manul Installer ==="
echo "Canonical source: $CANONICAL_DIR"
echo "Runtime target:   $RUNTIME_DIR"
echo

# 0. Verify required commands before claiming success. Do not invent
# dependencies; these are what the current Manul runtime actually needs:
#   bash      - all canonical scripts are bash
#   git       - worktrees / repo operations
#   gh        - GitHub API (polling, comments, PRs)
#   jq        - config.json parsing throughout the runtime
#   sqlite3   - manul.db (native ext4 I/O, concurrent access)
#   curl      - HTTP used by manul-comments-remove.sh
#   openclaw  - the agent runtime the daemon invokes
MISSING_DEPS=()
for cmd in bash git gh jq sqlite3 curl openclaw crontab; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_DEPS+=("$cmd")
    fi
done
if [ "${#MISSING_DEPS[@]}" -gt 0 ]; then
    echo "ERROR: Missing required dependencies: ${MISSING_DEPS[*]}" >&2
    echo "Install them before running this installer." >&2
    exit 1
fi
echo "Prerequisites OK: bash git jq sqlite3 curl openclaw crontab"
echo

# 2. Ensure runtime directory
if [ ! -d "$RUNTIME_DIR" ]; then
    echo "[1/7] Creating runtime directory: $RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
else
    echo "[1/7] Runtime directory exists: $RUNTIME_DIR"
fi

# 3. Deploy symlinks
echo
echo "[2/7] Deploying symlinks..."
"$CANONICAL_DIR/install-manul-symlinks.sh" \
    --runtime-dir "$RUNTIME_DIR" \
    --canonical-dir "$CANONICAL_DIR" || \
    fail "Symlink deployment failed"

# 4. Restore config.json from example if missing
echo
if [ ! -f "$RUNTIME_DIR/config.json" ]; then
    echo "[3/7] Config not found, restoring template..."
    cp "$CANONICAL_DIR/config.json.example" "$RUNTIME_DIR/config.json"
    echo "  Copied config.json.example -> config.json"
    echo "  WARNING: Edit $RUNTIME_DIR/config.json before starting the daemon"
else
    echo "[3/7] Config exists: $RUNTIME_DIR/config.json"
fi

if ! jq empty "$RUNTIME_DIR/config.json" >/dev/null 2>&1; then
    fail "Invalid JSON in $RUNTIME_DIR/config.json"
fi

# 5. Bootstrap/migrate the DB
#    - missing/empty file -> init_schema creates the schema
#    - valid SQLite file -> init_schema/workspace_init are idempotent
#    - schema initialization failure -> preserve old DB and bootstrap a fresh one
#
# Old data is disposable for installation purposes, but the previous DB is
# always preserved as a timestamped .old-* file before replacement.
echo
DB_FILE="$RUNTIME_DIR/manul.db"
BOOTSTRAP_FRESH=false

backup_db() {
    [ -f "$DB_FILE" ] || return 0
    local base="${DB_FILE}.old-$(date +%Y%m%d-%H%M%S)"
    local backup="$base"
    local n=1
    while [ -e "$backup" ] || [ -e "${backup}-wal" ] || [ -e "${backup}-shm" ]; do
        backup="${base}-${n}"
        n=$((n + 1))
    done
    mv "$DB_FILE" "$backup" || return 1
    # Preserve SQLite sidecars with the DB backup so an old WAL cannot be
    # accidentally applied to the newly-created database.
    if [ -e "${DB_FILE}-wal" ]; then
        mv "${DB_FILE}-wal" "${backup}-wal" || return 1
    fi
    if [ -e "${DB_FILE}-shm" ]; then
        mv "${DB_FILE}-shm" "${backup}-shm" || return 1
    fi
    echo "  Previous DB preserved as: $backup"
}

reset_to_fresh_db() {
    if [ -f "$DB_FILE" ]; then
        backup_db || fail "Could not preserve existing DB before fresh bootstrap"
    else
        rm -f "${DB_FILE}-wal" "${DB_FILE}-shm"
    fi
    rm -f "$DB_FILE"
    BOOTSTRAP_FRESH=true
}

if [ ! -f "$DB_FILE" ]; then
    echo "[4/7] DB not found, bootstrapping fresh..."
    BOOTSTRAP_FRESH=true
elif [ ! -s "$DB_FILE" ]; then
    echo "[4/7] DB is empty, bootstrapping fresh..."
    rm -f "$DB_FILE"
    BOOTSTRAP_FRESH=true
elif ! head -c 16 "$DB_FILE" 2>/dev/null | grep -q "^SQLite format 3"; then
    echo "[4/7] Existing DB is not SQLite; replacing with a fresh DB..."
    reset_to_fresh_db
elif ! sqlite3 "$DB_FILE" "PRAGMA integrity_check;" 2>/dev/null | grep -q "^ok$"; then
    echo "[4/7] Existing DB failed integrity check; replacing with a fresh DB..."
    reset_to_fresh_db
else
    echo "[4/7] DB present and valid, validating/migrating schema..."
fi

export MANUL_DIR="$RUNTIME_DIR"
export DB="$DB_FILE"

init_current_db() {
    "$RUNTIME_DIR/manul-conversation.sh" init-schema &&
    bash -c 'source "$1"; workspace_init' _ "$CANONICAL_DIR/workspace-manager.sh"
}

if ! init_current_db; then
    echo "WARNING: current DB schema initialization failed; replacing the DB with a fresh schema..." >&2
    reset_to_fresh_db
    init_current_db || fail "Fresh DB schema initialization failed"
}

REQUIRED_TABLES="processed_comments conversations meta workspaces"
for table in $REQUIRED_TABLES; do
    if ! sqlite3 "$DB_FILE" "SELECT 1 FROM $table LIMIT 1;" >/dev/null 2>&1; then
        fail "Required table '$table' is missing from $DB_FILE"
    fi
done
echo "  Required tables present: $REQUIRED_TABLES"
if $BOOTSTRAP_FRESH; then
    echo "  Fresh DB bootstrap complete"
fi

# 6. Install watchdog cron + zsh shell integration.
#    Neither operation starts the daemon. The watchdog is dormant until .enabled
#    is created by an intentional start.
WATCHDOG_CRON="*/5 * * * * $RUNTIME_DIR/watchdog.sh"
if crontab -l 2>/dev/null | grep -qF "$WATCHDOG_CRON"; then
    echo
    echo "[5/7] Watchdog cron already installed"
else
    echo
    echo "[5/7] Installing watchdog cron (dormant until .enabled exists)..."
    (crontab -l 2>/dev/null; echo "$WATCHDOG_CRON") | crontab - || \
        fail "Could not install watchdog cron"
fi

ZSHRC="$HOME/.zshrc"
MANUL_SHELL_LINE="source \"$CANONICAL_DIR/manul-shell.zsh\""
if [ ! -f "$ZSHRC" ]; then
    touch "$ZSHRC" || fail "Could not create $ZSHRC"
fi
if grep -Fq "$MANUL_SHELL_LINE" "$ZSHRC"; then
    echo "[6/7] Manul zsh integration already installed"
else
    echo >> "$ZSHRC"
    echo "# Manul CLI (managed by globalskills)" >> "$ZSHRC"
    echo "$MANUL_SHELL_LINE" >> "$ZSHRC"
    echo "[6/7] Installed Manul zsh integration"
fi

echo
echo "[7/7] Runtime prepared (not started)."
echo "  .enabled marker: absent"
echo "  Watchdog cron: installed but dormant until an intentional start"

# 7. Verify
echo
echo "=== Verification ==="
VERIFY_OK=true
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh \
             start-manul-automation.sh watchdog.sh; do
    if [ -L "$RUNTIME_DIR/$entry" ] && [ -f "$(readlink -f "$RUNTIME_DIR/$entry")" ]; then
        echo "OK $entry -> $(readlink "$RUNTIME_DIR/$entry")"
    else
        echo "FAIL $entry: missing or broken symlink" >&2
        VERIFY_OK=false
    fi
done

for data in config.json manul.db; do
    if [ -f "$RUNTIME_DIR/$data" ]; then
        echo "OK $data present"
    else
        echo "FAIL $data missing" >&2
        VERIFY_OK=false
    fi
done

if grep -Fq "$MANUL_SHELL_LINE" "$ZSHRC"; then
    echo "OK zsh integration present"
else
    echo "FAIL zsh integration missing from $ZSHRC" >&2
    VERIFY_OK=false
fi

if crontab -l 2>/dev/null | grep -qF "$WATCHDOG_CRON"; then
    echo "OK watchdog cron present"
else
    echo "FAIL watchdog cron missing" >&2
    VERIFY_OK=false
fi

echo
if $VERIFY_OK; then
    echo "=== Install Complete ==="
    echo "Runtime:    $RUNTIME_DIR"
    echo "Canonical:  $CANONICAL_DIR"
    echo
    echo "Start Manul manually with:"
    echo "  manul"
    echo "  # or explicitly:"
    echo "  $RUNTIME_DIR/start-manul-automation.sh start"
    exit 0
else
    echo "ERROR: installation verification failed" >&2
    exit 1
fi