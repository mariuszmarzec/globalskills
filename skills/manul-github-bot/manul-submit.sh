#!/bin/bash
# manul-submit.sh - Submit a task to the Manul task queue
#
# Usage:
#   manul-submit.sh [OPTIONS]
#
# Options:
#   --repo REPO          Repository (required, format: owner/repo)
#   --issue ISSUE        Issue or PR number (required)
#   --comment URL        Comment URL for conversation grouping (optional)
#   --prompt TEXT        Task prompt (required, or read from stdin)
#   --conversation ID    Conversation ID for grouping (optional, auto-generated if omitted)
#   --parent TASK_ID     Parent task ID for subtasks (optional)
#   --agent AGENT        Agent name (optional, defaults to "main")
#   --json               Output JSON format
#
# Returns:
#   JSON with commentId, conversationId, status on success
#   Exit code 0 on success, 1 on failure
#
# Examples:
#   manul-submit.sh --repo owner/repo --issue 1 --prompt "Fix bug"
#   manul-submit.sh --repo owner/repo --issue 1 --comment "https://github.com/..." --prompt "Reply to this"
#   echo "Fix bug" | manul-submit.sh --repo owner/repo --issue 1
#
# Idempotency:
#   If called multiple times with the same --repo, --issue, and --comment,
#   the same task ID is returned (if task still queued).

set -euo pipefail

# Configuration
MANUL_DIR="${MANUL_DIR:-${OPENCLAW_MANUL_DIR:-$HOME/.openclaw/manul}}"
DB="$MANUL_DIR/manul.db"
CONFIG="$MANUL_DIR/config.json"
OUTPUT_FORMAT="text"

# Parse arguments
REPO=""
ISSUE=""
COMMENT_URL=""
PROMPT=""
CONVERSATION=""
PARENT_TASK_ID=""
AGENT="main"

while [[ $# -gt 0 ]]; do
  case $1 in
    --repo) REPO="$2"; shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --comment) COMMENT_URL="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --conversation) CONVERSATION="$2"; shift 2 ;;
    --parent) PARENT_TASK_ID="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Read prompt from stdin if not provided
if [ -z "$PROMPT" ]; then
  if [ ! -t 0 ]; then
    PROMPT="$(cat)"
  else
    echo "Error: --prompt is required (or pipe via stdin)" >&2
    exit 1
  fi
fi

# Validate required fields
if [ -z "$REPO" ]; then
  echo "Error: --repo is required" >&2
  echo "Usage: manul-submit.sh --repo OWNER/REPO --issue NUMBER --prompt TEXT" >&2
  exit 1
fi

if [ -z "$ISSUE" ]; then
  echo "Error: --issue is required" >&2
  echo "Usage: manul-submit.sh --repo OWNER/REPO --issue NUMBER --prompt TEXT" >&2
  exit 1
fi

# Validate repo format
if [[ ! "$REPO" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
  echo "Error: --repo must be in format 'owner/repo'" >&2
  exit 1
fi

# Validate issue is a number
if [[ ! "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "Error: --issue must be a number" >&2
  exit 1
fi

# Generate comment ID (stable for idempotency when same params)
# Uses repo+issue+comment+prompt hash as primary key, appends timestamp+PID for uniqueness
_HASH_INPUT="$(printf '%s-%s-%s-%s' "$REPO" "$ISSUE" "$COMMENT_URL" "$PROMPT")"
_BASE_ID="cli-$(printf '%s' "$_HASH_INPUT" | md5sum | cut -d' ' -f1)"
COMMENT_ID="$_BASE_ID-$(date +%s)-$$"

# For true idempotency: if a recent queued task exists with same base ID, return it
if [ -f "$DB" ]; then
  _ESCAPED_BASE="$(printf '%s' "$_BASE_ID" | sed "s/'/''/g")"
  _SQL_QUERY="SELECT commentId FROM processed_comments WHERE commentId LIKE '$_ESCAPED_BASE-%' AND status='queued' ORDER BY createdAt DESC LIMIT 1;"
  EXISTING="$(sqlite3 "$DB" "$_SQL_QUERY" 2>/dev/null || echo "")"
  if [ -n "$EXISTING" ]; then
    COMMENT_ID="$EXISTING"
  else
    # No existing queued task - generate new unique ID with timestamp+PID
    COMMENT_ID="$_BASE_ID-$(date +%s)-$$"
  fi
fi

# Generate conversation ID if not provided
if [ -z "$CONVERSATION" ]; then
  if [ -n "$COMMENT_URL" ]; then
    # Use comment URL for conversation grouping
    CONVERSATION="$(printf '%s' "$COMMENT_URL" | md5sum | cut -d' ' -f1 | cut -c1-16)"
  else
    # Use repo+issue for conversation grouping
    CONVERSATION="conv-$(printf '%s-%s' "$REPO" "$ISSUE" | md5sum | cut -d' ' -f1 | cut -c1-8)"
  fi
fi

# Ensure database exists
if [ ! -f "$DB" ]; then
  echo "Error: Manul database not found at $DB" >&2
  exit 1
fi

# Source workspace manager for schema migration
source "$MANUL_DIR/workspace-manager.sh" 2>/dev/null || true

# Escape strings for SQL
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

ESCAPED_REPO="$(sql_escape "$REPO")"
ESCAPED_ISSUE="$ISSUE"
ESCAPED_COMMENT_URL="$(sql_escape "$COMMENT_URL")"
ESCAPED_PROMPT="$(sql_escape "$PROMPT")"
ESCAPED_CONVERSATION="$(sql_escape "$CONVERSATION")"
ESCAPED_PARENT="$(sql_escape "$PARENT_TASK_ID")"
ESCAPED_AGENT="$(sql_escape "$AGENT")"

# Insert or update task (idempotent by commentId)
# Using INSERT OR REPLACE for idempotency
sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments
  (commentId, repository, issueNumber, commentUrl, prompt, status, conversationId, parentTaskId, agent, createdAt)
  VALUES
  ('$COMMENT_ID', '$ESCAPED_REPO', $ESCAPED_ISSUE, '$ESCAPED_COMMENT_URL', '$ESCAPED_PROMPT', 'queued', '$ESCAPED_CONVERSATION', '$ESCAPED_PARENT', '$ESCAPED_AGENT', datetime('now'));"

# Output result
if [ "$OUTPUT_FORMAT" = "json" ]; then
  printf '{"commentId": "%s", "conversationId": "%s", "status": "queued", "repo": "%s", "issue": %s}\n' \
    "$COMMENT_ID" "$CONVERSATION" "$REPO" "$ISSUE"
else
  echo "Submitted task:"
  echo "  commentId:  $COMMENT_ID"
  echo "  repo:       $REPO#$ISSUE"
  echo "  conversation: $CONVERSATION"
  echo "  status:     queued"
fi

exit 0
