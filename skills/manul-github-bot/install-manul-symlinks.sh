#!/bin/bash
# install-manul-symlinks.sh — Deploy Manul scripts via symlinks from canonical source
#
# This script creates symlinks from the runtime directory to the canonical
# skill source, enabling a single source of truth for all Manul executable code.
#
# Usage:
#   install-manul-symlinks.sh [--runtime-dir <path>] [--canonical-dir <path>] [--dry-run]
#
# Options:
#   --runtime-dir    Runtime scripts directory (default: /mnt/f/ubuntu-workspace/.openclaw/manul)
#   --canonical-dir  Canonical skill source directory (default: ~/.globalskills/skills/manul-github-bot)
#   --dry-run        Show what would be done without making changes
#
# Safety:
#   - Preserves runtime data (config.json, manul.db, logs, workspace)
#   - Only removes regular file copies; never deletes data directories
#   - Creates absolute symlinks pointing to canonical source

set -euo pipefail

# Defaults
RUNTIME_DIR="${MANUL_RUNTIME_DIR:-/mnt/f/ubuntu-workspace/.openclaw/manul}"
CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --runtime-dir)
            RUNTIME_DIR="$2"
            shift 2
            ;;
        --canonical-dir)
            CANONICAL_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--runtime-dir <path>] [--canonical-dir <path>] [--dry-run]" >&2
            exit 1
            ;;
    esac
done

# Verify canonical directory exists
if [ ! -d "$CANONICAL_DIR" ]; then
    echo "ERROR: Canonical directory not found: $CANONICAL_DIR" >&2
    exit 1
fi

# List of scripts to symlink (in executable order)
SCRIPTS=(
    "feedback.sh"
    "github-api-wrapper.sh"
    "manul-comments-remove.sh"
    "manul-daemon.sh"
    "manul-status.sh"
    "poll.sh"
    "start-manul-automation.sh"
    "task-recovery.sh"
    "watchdog.sh"
)

echo "=== Manul Symlink Installer ==="
echo "Canonical source: $CANONICAL_DIR"
echo "Runtime target:   $RUNTIME_DIR"
echo "Dry run:          $DRY_RUN"
echo

# Create runtime directory if needed
if [ ! -d "$RUNTIME_DIR" ]; then
    if $DRY_RUN; then
        echo "[dry-run] Would create runtime directory: $RUNTIME_DIR"
    else
        mkdir -p "$RUNTIME_DIR"
        echo "Created runtime directory: $RUNTIME_DIR"
    fi
fi

# Deploy each script
CHANGED=0
for script in "${SCRIPTS[@]}"; do
    canonical_file="$CANONICAL_DIR/$script"
    runtime_path="$RUNTIME_DIR/$script"

    if [ ! -f "$canonical_file" ]; then
        echo "WARNING: Canonical script not found: $canonical_file" >&2
        continue
    fi

    # Check current state
    if [ -L "$runtime_path" ]; then
        current_target="$(readlink "$runtime_path")"
        if [ "$current_target" = "$canonical_file" ]; then
            echo "OK $script: symlink already correct"
            continue
        else
            echo "Updating $script: $current_target -> $canonical_file"
        fi
    elif [ -f "$runtime_path" ]; then
        echo "Converting $script: regular file -> symlink"
    else
        echo "Creating $script: new symlink"
    fi

    if $DRY_RUN; then
        echo "  [dry-run] Would create symlink: $runtime_path -> $canonical_file"
    else
        # Remove existing file (if regular file, not directory)
        if [ -f "$runtime_path" ] && [ ! -L "$runtime_path" ]; then
            rm -f "$runtime_path"
        fi
        # Create symlink (absolute path)
        ln -s "$canonical_file" "$runtime_path"
        # Ensure executable
        chmod +x "$runtime_path"
    fi
    CHANGED=$((CHANGED + 1))
done

# Verify deployment
echo
echo "=== Verification ==="
for script in "${SCRIPTS[@]}"; do
    runtime_path="$RUNTIME_DIR/$script"
    if [ -L "$runtime_path" ]; then
        target="$(readlink "$runtime_path")"
        if [ -f "$target" ]; then
            echo "OK $script -> $target"
        else
            echo "FAIL $script -> BROKEN: $target"
        fi
    else
        echo "FAIL $script: NOT a symlink"
    fi
done

# Summary
echo
if $DRY_RUN; then
    echo "Dry run complete. No changes made."
else
    echo "Deployment complete. $CHANGED script(s) updated."
    echo
    echo "Runtime data preserved:"
    echo "  - $RUNTIME_DIR/config.json"
    echo "  - $RUNTIME_DIR/manul.db"
    echo "  - $RUNTIME_DIR/*.log"
    echo "  - $RUNTIME_DIR/tasks/"
    echo "  - $RUNTIME_DIR/repo-locks/"
    echo "  - $RUNTIME_DIR/workspace/"
fi
