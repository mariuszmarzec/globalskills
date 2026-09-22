#!/usr/bin/env zsh
# manul-shell.zsh — Manul CLI entrypoints for interactive shells.
#
# Source this from ~/.zshrc:
#   source "$HOME/.globalskills/skills/manul-github-bot/manul-shell.zsh"
#
# All three CLI entrypoints point at the CANONICAL source scripts, never at the
# runtime dir. This means deleting/archiving ~/.openclaw/manul can never
# permanently break `manul`, `manul-status`, or `manul-comments-remove`.
#
# Self-healing: manul-ensure-runtime() runs the full canonical installer
# (install-manul.sh: symlinks + config + DB + .enabled marker) whenever the
# runtime is missing or any CLI entrypoint is not a usable file. The installer
# is idempotent and lives in the canonical source, so this works even when the
# whole runtime is gone. Checking all three entrypoints (not just
# manul-daemon.sh) means a broken/missing manul-status.sh or
# manul-comments-remove.sh is also repaired.
#
# The `.enabled` marker is the lifecycle contract:
#   - install-manul.sh prepares the runtime but does NOT start anything and does
#     NOT create the marker.
#   - the `manul` alias / start-manul-automation.sh start (intentional start)
#     CREATE it.
#   - start-manul-automation.sh stop / manul-daemon.sh stop REMOVE it.
#   - watchdog.sh only restarts the daemon when it is present, so crash recovery
#     never re-enables automation.

MANUL_CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"
MANUL_RUNTIME_DIR="${MANUL_RUNTIME_DIR:-$HOME/.openclaw/manul}"
MANUL_INSTALLER="$MANUL_CANONICAL_DIR/install-manul.sh"
MANUL_AUTOMATION="$MANUL_CANONICAL_DIR/start-manul-automation.sh"

manul-ensure-runtime() {
    local installer="$MANUL_INSTALLER"
    if [ ! -d "$MANUL_RUNTIME_DIR" ] \
       || [ ! -f "$MANUL_RUNTIME_DIR/manul-daemon.sh" ] \
       || [ ! -f "$MANUL_RUNTIME_DIR/manul-status.sh" ] \
       || [ ! -f "$MANUL_RUNTIME_DIR/manul-comments-remove.sh" ]; then
        "$installer" >/dev/null 2>&1 || true
    fi
}

# `manul` is the intentional-start path: it ensures the runtime, then starts
# the daemon AND installs the watchdog cron. This creates the .enabled marker
# (via start-manul-automation.sh start) so the watchdog is allowed to recover it.
alias manul='manul-ensure-runtime; "$MANUL_AUTOMATION" start'
alias manul-status='manul-ensure-runtime; "$MANUL_CANONICAL_DIR/manul-status.sh"'
alias manul-comments-remove='manul-ensure-runtime; "$MANUL_CANONICAL_DIR/manul-comments-remove.sh"'