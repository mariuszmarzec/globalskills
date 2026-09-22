#!/bin/bash
# install-manul.sh — Canonical Manul installer
#
# Idempotent one-shot bootstrap of a fresh Manul runtime:
#   1. Self-detect canonical source
#   2. Validate canonical source
#   3. Ensure runtime directory
#   4. Deploy symlinks via install-manul-symlinks.sh
#   5. Restore config.json from example if missing
#   6. Bootstrap/migrate manul.db (create+init if missing; migrate if valid;
#      abort if corrupt)
#   7. Mark the runtime as intentionally enabled (.enabled)
#   8. Verify and print summary
#
# This installer does NOT start the daemon and does NOT install the watchdog
# cron. Intentional start (the `manul` alias / start-manul-automation.sh) is a
# separate step. That separation is the whole point of the `.enabled` marker:
# the watchdog only restarts the daemon when `.enabled` is present, so a fresh
# install is intentionally-enabled while crash recovery never re-enables it.
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
             manul-conversation.sh workspace-manager.sh; do
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
for cmd in bash git gh jq sqlite3 curl openclaw; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_DEPS+=("$cmd")
    fi
done
if [ "${#MISSING_DEPS[@]}" -gt 0 ]; then
    echo "ERROR: Missing required dependencies: ${MISSING_DEPS[*]}" >&2
    echo "Install them before running this installer." >&2
    exit 1
fi
echo "Prerequisites OK: bash git gh jq sqlite3 curl openclaw"
echo

# 2. Ensure runtime directory
if [ ! -d "$RUNTIME_DIR" ]; then
    echo "[1/5] Creating runtime directory: $RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"
else
    echo "[1/5] Runtime directory exists: $RUNTIME_DIR"
fi

# 3. Deploy symlinks
echo
echo "[2/5] Deploying symlinks..."
"$CANONICAL_DIR/install-manul-symlinks.sh" \
    --runtime-dir "$RUNTIME_DIR" \
    --canonical-dir "$CANONICAL_DIR" || \
    fail "Symlink deployment failed"

# 4. Restore config.json from example if missing
echo
if [ ! -f "$RUNTIME_DIR/config.json" ]; then
    echo "[3/5] Config not found, restoring template..."
    cp "$CANONICAL_DIR/config.json.example" "$RUNTIME_DIR/config.json"
    echo "  Copied config.json.example -> config.json"
    echo "  WARNING: Edit $RUNTIME_DIR/config.json before starting the daemon"
else
    echo "[3/5] Config exists: $RUNTIME_DIR/config.json"
fi

if ! jq empty "$RUNTIME_DIR/config.json" >/dev/null 2>&1; then
    fail "Invalid JSON in $RUNTIME_DIR/config.json"
fi

# 5. Bootstrap/migrate the DB
#    - missing/empty file  -> init_schema creates the schema (bootstrap)
#    - valid SQLite file  -> init_schema is idempotent (migrate, preserved)
#    - corrupt file       -> moved aside as manul.db.old-<ts>, fresh DB bootstrapped
# A corrupt DB is NEVER silently migrated or overwritten; the old file is
# preserved as a timestamped backup so it can be restored manually if desired.
echo
DB_FILE="$RUNTIME_DIR/manul.db"
BOOTSTRAP_FRESH=false
if [ ! -f "$DB_FILE" ]; then
    echo "[4/5] DB not found, bootstrapping..."
    BOOTSTRAP_FRESH=true
elif [ ! -s "$DB_FILE" ]; then
    # Empty file: treat as missing, bootstrap fresh.
    echo "[4/5] DB is empty, bootstrapping..."
    rm -f "$DB_FILE"
    BOOTSTRAP_FRESH=true
elif ! head -c 16 "$DB_FILE" 2>/dev/null | grep -q "^SQLite format 3"; then
    # Not a SQLite file at all — preserve and bootstrap fresh.
    TS="$(date +%Y%m%d-%H%M%S)"
    mv "$DB_FILE" "${DB_FILE}.old-${TS}"
    echo "[4/5] Existing DB is not a SQLite database; moved to ${DB_FILE}.old-${TS}, bootstrapping fresh..."
    BOOTSTRAP_FRESH=true
elif ! sqlite3 "$DB_FILE" "PRAGMA integrity_check;" 2>/dev/null | grep -q "^ok$"; then
    # Corrupt SQLite — preserve and bootstrap fresh.
    TS="$(date +%Y%m%d-%H%M%S)"
    mv "$DB_FILE" "${DB_FILE}.old-${TS}"
    echo "[4/5] Existing DB failed integrity check; moved to ${DB_FILE}.old-${TS}, bootstrapping fresh..."
    BOOTSTRAP_FRESH=true
else
    echo "[4/5] DB present and valid, validating/migrating schema..."
fi

export MANUL_DIR="$RUNTIME_DIR"
export DB="$DB_FILE"

"$RUNTIME_DIR/manul-conversation.sh" init-schema || \
    fail "Canonical conversation schema initialization failed"

bash -c 'source "$1"; workspace_init' _ "$CANONICAL_DIR/workspace-manager.sh" || \
    fail "Canonical workspace initialization failed"

REQUIRED_TABLES="processed_comments conversations meta workspaces"
for table in $REQUIRED_TABLES; do
    if ! sqlite3 "$DB_FILE" "SELECT 1 FROM $table LIMIT 1;" >/dev/null 2>&1; then
        fail "Required table '$table' is missing from $DB_FILE"
    fi
done
echo "  Required tables present: $REQUIRED_TABLES"
if $BOOTSTRAP_FRESH; then
    echo "  (fresh DB bootstrap complete)"
fi

# 6. Intentional-enable marker is NOT created here.
#    install-manul.sh prepares the runtime but never starts the daemon and never
#    creates the .enabled marker. That marker is the lifecycle contract between
#    intentional start/stop and the watchdog, and it is created ONLY by an
#    explicit start (the `manul` alias / start-manul-automation.sh start).
#    If install-manul.sh created it, the watchdog would start the daemon on the
#    next cron tick — i.e. automatic startup from an install that promised not
#    to start anything.
echo
echo "[5/5] Runtime prepared (not started)."

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

echo
if $VERIFY_OK; then
    echo "=== Install Complete ==="
    echo "Runtime:    $RUNTIME_DIR"
    echo "Canonical:  $CANONICAL_DIR"
    echo
    echo "Start the automation with:"
    echo "  manul"
    echo "  # or explicitly:"
    echo "  $RUNTIME_DIR/start-manul-automation.sh start"
    exit 0
else
    echo "ERROR: installation verification failed" >&2
    exit 1
fi