#!/usr/bin/bash
# feedback.sh — Post a signed GitHub comment (used by poll.sh for skip-comment draining).
#
# Usage: feedback.sh <repo> <issue> [<message>]
#
# Posts a top-level issue/PR comment signed with the Manul identity.
# This script is intentionally simple: it handles the common case of
# top-level comments. For review-thread replies, manul-daemon.sh uses
# gh pr comment --in-reply-to directly.
#
# Usage by poll.sh: drains pending skip-comments.log entries after failed runs.
set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
LOG="${MANUL_DIR}/poll.log"

REPO="${1:-}"
ISSUE="${2:-}"
MSG="${3:-}"

[ -n "$REPO" ] || { echo "usage: feedback.sh <repo> <issue> [<msg>]" >&2; exit 1; }
[ -n "$ISSUE" ] || { echo "usage: feedback.sh <repo> <issue> [<msg>]" >&2; exit 1; }

SIG="— manul 🐈"
if [[ "$MSG" == *"$SIG" ]]; then
  SIGNED="$MSG"
else
  SIGNED="${MSG}"$'\n\n'"$SIG"
fi

gh issue comment "$ISSUE" --repo "$REPO" --body "$SIGNED" 2>>"$LOG"
