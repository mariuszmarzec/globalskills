#!/usr/bin/bash
# manul-poll.sh — GitHub /manul trigger poller for OpenClaw cron.
#
# Scans configured repos for issue comments + PR review comments containing the
# trigger command, queues unprocessed ones in SQLite
# and prints a single MANUL_RESULT line for the cron trigger wrapper.
#
# Usage: manul-poll.sh [repo...]   (repos override config for testing)
#
# State:
#   processed_comments(commentId PK, repository, issueNumber, commentUrl,
#                      author, prompt, status, createdAt, processedAt)
#     status: queued -> running -> done | failed
#   meta(baseline)   — BASELINE = manul install/config moment (UTC ISO).
#     Only issues/comments created AFTER baseline are considered, so manul
#     never picks up old posts after a (re)install on a new machine.
#     Set explicitly during install; falls back to first-run time if empty.
#   meta(baseline)   — BASELINE = manul install/config moment (UTC ISO).
set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="${MANUL_DIR}/config.json"
# DB on native ext4 (NOT on 9p /mnt/f)
DB="${MANUL_DIR}/manul.db"
LOCK="${MANUL_DIR}/lock"
LOG="${MANUL_DIR}/poll.log"
LOCK_TTL_SECONDS="${MANUL_LOCK_TTL_SECONDS:-1800}"
REPO_LOCK_DIR="${MANUL_DIR}/repo-locks"
REPO_LOCK_TTL="${MANUL_REPO_LOCK_TTL_SECONDS:-1800}"
LEASE_TIMEOUT="$(jq -r '.automation.leaseTimeout // 900' "$CONFIG" 2>/dev/null)"
LEASE_TIMEOUT="${LEASE_TIMEOUT:-900}"
mkdir -p "$REPO_LOCK_DIR" 2>/dev/null || true

log() { echo "[$(date -Is)] $*" >>"$LOG"; }
fail() { echo "MANUL_RESULT {\"fire\":false,\"error\":\"$1\"}"; exit 0; }

# SQL escaping helpers
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

sql_num() {
  local val="$1"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s' "$val"
  else
    printf ''
  fi
}

# Per-repo lock: prevents two different tasks from working on the same local
# repo workdir at the same time. Repo is identified by its workdir slug.
acquire_repo_lock() {
  local repo="$1"
  local slug
  slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  local lockfile="${REPO_LOCK_DIR}/${slug}.lock"
  if [ -f "$lockfile" ]; then
    local age
    age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$REPO_LOCK_TTL" ]; then
      log "repo $repo is locked by another task (age=${age}s, ttl=${REPO_LOCK_TTL}s); skipping"
      return 1
    fi
    # Lock is stale — but only remove it if no task is currently running for
    # this repo in DB. If a task is still marked `running`, the old worker
    # may still be alive; do NOT steal the lock.
    local running_count
    local safe_repo
    safe_repo="$(sql_escape "$repo")"
    running_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE repository='$safe_repo' AND status='running';" 2>/dev/null || echo 0)"
    if [ "${running_count:-0}" -gt 0 ]; then
      log "stale repo lock for $repo ignored because task is still running in DB (running=$running_count); skipping"
      return 1
    fi
    log "stale repo lock for $repo removed (age=${age}s, no running tasks)"
    rm -f "$lockfile"
  fi
  date +%s >"$lockfile"
  return 0
}
release_repo_lock() {
  local repo="$1"
  local slug
  slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  rm -f "${REPO_LOCK_DIR}/${slug}.lock"
}

[ -f "$CONFIG" ] || fail "no config at $CONFIG"
TRIGGER="$(jq -r '.trigger // "/manul"' "$CONFIG")"
[ -n "$TRIGGER" ] || TRIGGER="/manul"

# Bot signature: any comment ending with this is manul's OWN comment
# (feedback.sh signs every comment). Skip them so manul never re-triggers
# itself — e.g. a Done comment mentioning a path like docs/manul-… would
# otherwise match the trigger substring.
SIG="— manul 🐈"

# Known role agents (from config.json `.agents`, fallback = skill's role set).
# The parser sets `.agent` only when the first token after the trigger on the
# trigger line matches one of these (case-sensitive exact). Anything else stays
# in the prompt and the orchestrator decides (default coder).
mapfile -t AGENTS < <(jq -r '.agents[]?' "$CONFIG" 2>/dev/null)
if [ "${#AGENTS[@]}" -eq 0 ]; then
  AGENTS=(architect coder coder-cheap coder-strong coder-expert reviewer reviewer-expert debugger debugger-expert researcher tester security performance refactorer)
fi
AGENTS_JSON="$(printf '%s\n' "${AGENTS[@]}" | jq -R . | jq -sc .)"

# Shared jq: extract (agent, prompt) from a comment/issue body.
# - find the first line containing the trigger,
# - everything after the trigger on that line = rest0 (leading spaces trimmed),
# - if rest0 is empty, the following lines become the prompt,
# - first token of the rest: known agent name => agent; the remainder = prompt.
PARSE='(.body | split("\n")) as $lines
| ([range(0; $lines|length) | select($lines[.] | contains($trig))][0]) as $idx
| ($lines[$idx] | split($trig) | .[1:] | join($trig) | sub("^[ \t]+"; "")) as $rest0
| (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else $rest0 end) as $rest
| ($rest | split(" ")[0]) as $tok
| (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
| (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt
| {agent: $agent, prompt: $prompt}'

# Only these GitHub logins may invoke manul. Default: repo owner.
ALLOWED_JSON="$(jq -c '.allowedUsers // ([.repositories[]? | split("/")[0]] | if length == 0 then [] else . end)' "$CONFIG" 2>/dev/null)"
if [ -z "$ALLOWED_JSON" ] || [ "$ALLOWED_JSON" = "null" ]; then
  ALLOWED_JSON='[]'
fi

# CI Fix config
CI_FIX_ENABLED="$(jq -r '.ciFix.enabled // false' "$CONFIG" 2>/dev/null)"
CI_FIX_MAX_ATTEMPTS="$(jq -r '.ciFix.maxAttemptsPerRun // 2' "$CONFIG" 2>/dev/null)"
CI_FIX_COOLDOWN_MINUTES="$(jq -r '.ciFix.cooldownMinutes // 60' "$CONFIG" 2>/dev/null)"

if [ "$CI_FIX_ENABLED" = "null" ]; then CI_FIX_ENABLED="false"; fi
if [ "$CI_FIX_MAX_ATTEMPTS" = "null" ]; then CI_FIX_MAX_ATTEMPTS="2"; fi
if [ "$CI_FIX_COOLDOWN_MINUTES" = "null" ]; then CI_FIX_COOLDOWN_MINUTES="60"; fi

# Generate conversation ID for task grouping
# Returns a deterministic conversation ID based on commentUrl (not just issue)
# This allows multiple independent conversations on the same issue/PR
# Generate the canonical conversation ID.
#
# Conversation identity is NOT a comment identity.
#
# Rules:
#   issue / issue-body / PR top-level conversation:
#       conv-<repo>-issue-<issue>
#
#   PR inline review thread:
#       conv-<repo>-review-<root-review-comment-id>
#
# IMPORTANT:
#   Never use commentUrl as conversation identity.
generate_conversation_id() {
  local repo="$1"
  local issue="$2"
  local kind="${3:-issue}"
  local thread_id="${4:-}"

  case "$kind" in
    review-thread)
      [ -n "$thread_id" ] || {
        log "ERROR: review-thread conversation requires thread_id"
        return 1
      }
      printf 'conv-%s-review-%s' "$repo" "$thread_id"
      ;;
    issue|pr-top-level)
      printf 'conv-%s-issue-%s' "$repo" "$issue"
      ;;
    *)
      log "ERROR: unknown conversation kind: $kind"
      return 1
      ;;
  esac
}

# Return the root review-comment id for a PR review thread.
#
# GitHub inline review replies contain `in_reply_to_id`.
# A top-level review comment has no `in_reply_to_id` and is therefore its own
# thread root.
get_review_thread_root_id() {
  local comments_json="$1"
  local comment_id="$2"
  local current="$comment_id"
  local parent=""
  local guard=0
  while [ -n "$current" ] && [ "$guard" -lt 100 ]; do
    parent="$(
      printf '%s' "$comments_json" |
        jq -r --arg id "$current" '
          .[] | select((.id | tostring) == $id) | (.in_reply_to_id // empty)
        ' 2>/dev/null |
        head -n1
    )"
    if [ -z "$parent" ] || [ "$parent" = "null" ]; then
      printf '%s' "$current"
      return 0
    fi
    current="$parent"
    guard=$((guard + 1))
  done
  printf '%s' "$comment_id"
}


persist_conversation_message() {
  # Args:
  #   conv_id repo issue comment_id author body url created_at message_type
  local conv_id="$1"
  local repo="$2"
  local issue="$3"
  local comment_id="$4"
  local author="$5"
  local body="$6"
  local url="$7"
  local created="$8"
  local message_type="${9:-comment}"

  [ -n "$conv_id" ] || return 0
  [ -n "$comment_id" ] || return 0

  # Idempotency: skip if this (conversationId, commentId) pair already exists.
  local already_persisted
  already_persisted="$(sqlite3 "$DB" "
    SELECT 1
    FROM conversation_messages
    WHERE conversationId='$(sql_escape "$conv_id")'
      AND commentId='$(sql_escape "$comment_id")'
    LIMIT 1;
  " 2>/dev/null || true)"
  [ "$already_persisted" = "1" ] && return 0

  local esc_repo esc_author esc_body esc_url esc_type message_id
  esc_repo="$(sql_escape "$repo")"
  esc_author="$(sql_escape "$author")"
  esc_body="$(sql_escape "$body")"
  esc_url="$(sql_escape "$url")"
  esc_type="$(sql_escape "$message_type")"
  message_id="$(uuidgen)"

  sqlite3 "$DB" "
    INSERT OR IGNORE INTO conversation_messages(
      messageId,
      conversationId,
      commentId,
      repo,
      issueNumber,
      author,
      body,
      commentUrl,
      createdAt,
      messageType
    )
    VALUES(
      '$message_id',
      '$(sql_escape "$conv_id")',
      '$(sql_escape "$comment_id")',
      '$esc_repo',
      $issue,
      '$esc_author',
      '$esc_body',
      '$esc_url',
      '$(sql_escape "$created")',
      '$esc_type'
    );
  " 2>>"$LOG" || true
}

ensure_conversation() {
  local conv_id="$1"
  local repo="$2"
  local issue="$3"
  local issue_url="$4"

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "
    INSERT OR IGNORE INTO conversations(
      conversationId,
      repository,
      issueNumber,
      issueUrl,
      status,
      createdAt,
      updatedAt
    )
    VALUES(
      '$(sql_escape "$conv_id")',
      '$(sql_escape "$repo")',
      $issue,
      '$(sql_escape "$issue_url")',
      'OPEN',
      '$now',
      '$now'
    );

    UPDATE conversations
    SET updatedAt='$now'
    WHERE conversationId='$(sql_escape "$conv_id")';
  " 2>>"$LOG" || true
}

build_conversation_context() {
  local conv_id="$1"

  sqlite3 -separator $'\t' "$DB" "
    SELECT
      author,
      messageType,
      body,
      commentId,
      commentUrl,
      createdAt
    FROM conversation_messages
    WHERE conversationId='$(sql_escape "$conv_id")'
    ORDER BY createdAt ASC, rowid ASC;
  " 2>/dev/null |
  while IFS=$'\t' read -r author message_type body comment_id comment_url created_at; do
    printf '[%s] %s (%s)\n%s\n\n'       "$created_at" "$author" "$message_type" "$body"
  done
}

persist_conversation_messages_for_repo() {
  # After processing trigger comments, also persist ALL non-trigger comments
  # on the same issues/PRs as conversation history. This ensures the daemon
  # has full thread context even for messages that didn't contain /manul.
  #
  # Requirement: persist ALL conversation messages regardless of task status.
  # Even completed/resolved tasks should have their conversation context preserved
  # so the bot can reference full thread history.
  local repo="$1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Get all issue/PR numbers that have ANY processed comments (not just queued/running)
  local affected_ids
  affected_ids="$(sqlite3 "$DB" "SELECT DISTINCT issueNumber FROM processed_comments WHERE repository='$(sql_escape "$repo")';" 2>>"$LOG")" || true

  [ -z "$affected_ids" ] && return 0

  for issue_num in $affected_ids; do
    [ -n "$issue_num" ] || continue
    # Determine if this is a PR or issue
    local is_pr=0
    [ -n "${OPEN_PRS[$issue_num]:-}" ] && is_pr=1
    [ -n "${MERGED_PRS[$issue_num]:-}" ] && is_pr=1
    [ -n "${CLOSED_PRS[$issue_num]:-}" ] && is_pr=1

    local conv_id
    conv_id="$(generate_conversation_id "$repo" "$issue_num" "issue")" || continue

    local comments_json
    if [ "$is_pr" -eq 1 ]; then
      comments_json="$(gh api --paginate "repos/$repo/issues/$issue_num/comments?per_page=100" 2>>"$LOG" || echo "[]")"
    else
      comments_json="$(gh api --paginate "repos/$repo/issues/$issue_num/comments?per_page=100" 2>>"$LOG" || echo "[]")"
    fi

    # Get existing message comment IDs for this conversation to avoid re-persisting
    local existing_ids
    existing_ids="$(sqlite3 "$DB" "
      SELECT commentId
      FROM conversation_messages
      WHERE conversationId='$(sql_escape "$conv_id")'
        AND repo='$(sql_escape "$repo")'
        AND issueNumber=$issue_num;
    " 2>>"$LOG" || echo "")"

    while IFS= read -r comment; do
      [ -n "$comment" ] || continue
      local c_id c_author c_body c_url c_created
      c_id="$(jq -r '.id' <<<"$comment")"
      c_author="$(jq -r '.user.login // .login // "unknown"' <<<"$comment")"
      c_body="$(jq -r '.body // ""' <<<"$comment")"
      c_url="$(jq -r '.html_url // ""' <<<"$comment")"
      c_created="$(jq -r '.created_at // ""' <<<"$comment")"
      [ -n "$c_id" ] || continue
      [ -n "$c_url" ] || continue
      echo "$existing_ids" | grep -qxF "$c_id" && continue

      persist_conversation_message         "$conv_id" "$repo" "$issue_num" "$c_id" "$c_author"         "$c_body" "$c_url" "$c_created" "comment"

      existing_ids="$(printf '%s
%s' "$existing_ids" "$c_id")"
    done < <(echo "$comments_json" | jq -c '.[]' 2>/dev/null || true)

    # Also persist PR review comments for PRs — every comment, not just roots.
    if [ "$is_pr" -eq 1 ]; then
      local review_comments
      review_comments="$(gh api --paginate "repos/$repo/pulls/$issue_num/comments?per_page=100" 2>>"$LOG" || echo "[]")"

      while IFS= read -r comment; do
        [ -n "$comment" ] || continue
        local c_id c_author c_body c_url c_created root_id review_conv_id
        c_id="$(jq -r '.id' <<<"$comment")"
        c_author="$(jq -r '.user.login // .login // "unknown"' <<<"$comment")"
        c_body="$(jq -r '.body // ""' <<<"$comment")"
        c_url="$(jq -r '.html_url // ""' <<<"$comment")"
        c_created="$(jq -r '.created_at // ""' <<<"$comment")"
        [ -n "$c_id" ] || continue
        [ -n "$c_url" ] || continue

        # Determine thread root for conversation identity
        if [ "$(jq -r '.in_reply_to_id // empty' <<<"$comment")" = "" ]; then
          root_id="$c_id"
        else
          root_id="$(get_review_thread_root_id "$review_comments" "$c_id")"
        fi
        [ -n "$root_id" ] || continue

        review_conv_id="$(generate_conversation_id "$repo" "$issue_num" "review-thread" "$root_id")" || continue

        persist_conversation_message "$review_conv_id" "$repo" "$issue_num" "$c_id" "$c_author" "$c_body" "$c_url" "$c_created" "review-comment"
      done < <(echo "$review_comments" | jq -c '.[]' 2>/dev/null || true)
    fi
  done
}

# Close conversations whose active PR has been merged and have no remaining tasks.
# Idempotent: only touches conversations with status != 'COMPLETED'.
close_merged_pr_conversations() {
  local merged_pr_list="$1"
  [ -z "$merged_pr_list" ] && return 0

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local query_err
  query_err=$(sqlite3 "$DB" "
    SELECT c.conversationId FROM conversations c
    WHERE c.activePrNumber IN ($merged_pr_list)
      AND c.status != 'COMPLETED'
      AND NOT EXISTS (
        SELECT 1 FROM processed_comments t
        WHERE t.conversationId = c.conversationId
          AND t.status IN ('queued', 'running')
      );" 2>>"$LOG") || query_err="FAILED"
  if [ "$query_err" = "FAILED" ]; then
    log "ERROR: failed to query conversations for merged PR auto-close"
  else
    while IFS='|' read -r conv_id; do
      [ -n "$conv_id" ] || continue
      if sqlite3 "$DB" "UPDATE conversations SET status='COMPLETED', activePrNumber=NULL, activePrUrl=NULL, updatedAt='$now' WHERE conversationId='$(sql_escape "$conv_id")' AND status != 'COMPLETED';" 2>>"$LOG"; then
        log "auto-closed conversation $conv_id (merged PR has no remaining tasks)"
      else
        log "ERROR: failed to close conversation $conv_id (merged PR)"
      fi
    done <<<"$query_err"
  fi
}

if [ $# -gt 0 ]; then
  REPOS=("$@")
else
  mapfile -t REPOS < <(jq -r '.repositories[]?' "$CONFIG" 2>/dev/null)
fi

# === DB schema initialization and migration (runs on source) ===
mkdir -p "$MANUL_DIR"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments (
    commentId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    commentUrl TEXT NOT NULL,
    author TEXT,
    agent TEXT,
    prompt TEXT NOT NULL,
    context TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT,
    processedAt TEXT
);" 2>>"$LOG"
# migration for existing DBs (pre-agent column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|agent|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN agent TEXT;" 2>>"$LOG"
    log "migration: added agent column"
fi
# migration for existing DBs (pre-attempts column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|attempts|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;" 2>>"$LOG"
    log "migration: added attempts column"
fi
# migration for existing DBs (pre-context column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|context|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN context TEXT;" 2>>"$LOG"
    log "migration: added context column"
fi
# migration for existing DBs (pre-heartbeatAt column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|heartbeatAt|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;" 2>>"$LOG"
    log "migration: added heartbeatAt column"
fi
# migration for existing DBs (pre-leaseExpiresAt column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|leaseExpiresAt|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;" 2>>"$LOG"
    log "migration: added leaseExpiresAt column"
fi
# migration for existing DBs (pre-workerPid column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|workerPid|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;" 2>>"$LOG"
    log "migration: added workerPid column"
fi
# migration for existing DBs (pre-nextAttemptAt column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|nextAttemptAt|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;" 2>>"$LOG"
    # Set nextAttemptAt for existing retry tasks (attempts > 0) to allow gradual eligibility
    sqlite3 "$DB" "UPDATE processed_comments SET nextAttemptAt = datetime('now', '+60 seconds') WHERE status='queued' AND attempts > 0 AND nextAttemptAt IS NULL;" 2>>"$LOG"
    log "migration: added nextAttemptAt column"
fi
# migration for existing DBs (pre-concurrency fields)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|conversationId|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN conversationId TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN parentTaskId TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN workspaceId TEXT;" 2>>"$LOG"
    log "migration: added concurrency fields"
fi
# migration for existing DBs (pre-result fields)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|resultSummary|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN resultSummary TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN resultJson TEXT;" 2>>"$LOG"
    log "migration: added result fields"
fi
# migration for existing DBs (pre-baseId field for idempotency)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|baseId|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN baseId TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "CREATE UNIQUE INDEX IF NOT EXISTS idx_base_status ON processed_comments(baseId, status);" 2>>"$LOG"
    log "migration: added baseId column and unique index for idempotency"
fi
# migration for submission claims table (atomic idempotency)
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS submission_claims (
    baseId TEXT PRIMARY KEY,
    commentId TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    createdAt TEXT DEFAULT (datetime('now'))
);" 2>>"$LOG"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);" 2>>"$LOG"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversations(conversationId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, issueUrl TEXT, activePrNumber INTEGER, activePrUrl TEXT, activeTaskId TEXT, status TEXT NOT NULL DEFAULT 'OPEN', createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);" 2>>"$LOG"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversation_links(id INTEGER PRIMARY KEY AUTOINCREMENT, conversationId TEXT NOT NULL, repo TEXT NOT NULL, issueNumber INTEGER, prNumber INTEGER, commentId TEXT, taskCommentId TEXT, linkType TEXT NOT NULL, createdAt TEXT NOT NULL);" 2>>"$LOG"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversation_messages(messageId TEXT PRIMARY KEY, conversationId TEXT NOT NULL, commentId TEXT, repo TEXT, issueNumber INTEGER, author TEXT, body TEXT, commentUrl TEXT, createdAt TEXT, messageType TEXT);" 2>>"$LOG"

BASELINE="$(sqlite3 "$DB" "SELECT value FROM meta WHERE key='baseline';")"
if [ -z "$BASELINE" ]; then
    BASELINE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sqlite3 "$DB" "INSERT OR IGNORE INTO meta(key,value) VALUES('baseline','$BASELINE');" 2>>"$LOG"
    log "baseline set: $BASELINE"
fi

# === context enrichment helpers ===
declare -A CTX_PR_CACHE CTX_ISSUE_CACHE

extract_issue_refs() {
    local text="$1" repo="$2"
    printf '%s' "$text" | grep -oE 'https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+' | awk -v repo="$repo" '
      /^http/ { split($0, a, "/"); print a[4] "/" a[5], a[7] }
      /#/ && !/^http/ && index($0, "/") { split($0, a, "#"); print a[1], a[2] }
      /^#/ { sub(/^#/, ""); print repo, $0 }
    ' | sort -u
}

fetch_issue_ctx() {
    local repo="$1" n="$2" key="$repo#$n" j
    if [ -n "${CTX_ISSUE_CACHE[$key]:-}" ]; then
      printf '%s' "${CTX_ISSUE_CACHE[$key]}"
      return
    fi
    j="$(gh issue view "$n" --repo "$repo" --json number,title,body 2>/dev/null | jq -c '{number,title,body}' 2>/dev/null || true)"
    CTX_ISSUE_CACHE[$key]="$j"
    printf '%s' "$j"
}

build_review_context() {
    local repo="$1" pr="$2" path="$3" line="$4" hunk="$5"
    local key="$repo#$pr" pr_json issues_json r n issue_json
    if [ -n "${CTX_PR_CACHE[$key]:-}" ]; then
      pr_json="${CTX_PR_CACHE[$key]}"
    else
      pr_json="$(gh pr view "$pr" --repo "$repo" --json number,title,state,body 2>/dev/null | jq -c . 2>/dev/null || true)"
      [ -n "$pr_json" ] || pr_json='{"number":0,"title":"","state":"","body":""}'
      CTX_PR_CACHE[$key]="$pr_json"
    fi
    issues_json='[]'
    while read -r r n; do
      [ -n "${r:-}" ] || continue
      issue_json="$(fetch_issue_ctx "$r" "$n")"
      [ -n "$issue_json" ] && issues_json="$(printf '%s' "$issues_json" | jq -c --argjson x "$issue_json" '. + [$x]')"
    done <<< "$(extract_issue_refs "$(printf '%s' "$pr_json" | jq -r '.body // ""')" "$repo")"
    jq -nc --argjson pr "$pr_json" --argjson issues "$issues_json" --arg path "$path" --arg line "$line" --arg hunk "$hunk" '{pr:$pr, linkedIssues:$issues, comment:{path:$path,line:$line,diffHunk:$hunk}}'
}

build_issue_context() {
    local repo="$1" n="$2" issue_json
    issue_json="$(fetch_issue_ctx "$repo" "$n")"
    if [ -n "$issue_json" ]; then
      printf '%s' "$issue_json" | jq -c '{issue:.}'
    fi
}
# === end context enrichment helpers ===

# === ci fix helpers ===
# ci_fix_seen table: tracks PRs/runs we've already attempted to fix to avoid loops
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS ci_fix_seen (
    prNumber INTEGER NOT NULL,
    runId TEXT NOT NULL,
    attemptedAt TEXT NOT NULL,
    PRIMARY KEY (prNumber, runId)
);" 2>>"$LOG"

# ci_fix_failed table: records (repo, PR, head_sha) where a build-fix attempt
# already failed. While the PR head stays on this commit, the poller must NOT
# queue another build-fix task — the bot has already proven it could not fix
# this build, and adding more attempts would burn time and tokens without
# changing the result. When the PR head moves (new commit), the row no longer
# matches and a fresh fix is eligible again.
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS ci_fix_failed (
    repository TEXT NOT NULL,
    prNumber INTEGER NOT NULL,
    head_sha TEXT NOT NULL,
    branch TEXT,
    reason TEXT,
    failed_at TEXT NOT NULL,
    PRIMARY KEY (repository, prNumber, head_sha)
);" 2>>"$LOG"

# check_ci_fix_eligible <repo> <prNumber> <runId> -> returns 0 if eligible, 1 if not
check_ci_fix_eligible() {
    local repo="$1" pr="$2" run="$3"
    local key="$repo#$pr#$run"
    local pr_num
    pr_num="$(sql_num "$pr")"
    [ -n "$pr_num" ] || return 1
    local safe_run
    safe_run="$(sql_escape "$run")"
    local safe_repo
    safe_repo="$(sql_escape "$repo")"
    local seen
    seen="$(sqlite3 "$DB" "SELECT 1 FROM ci_fix_seen WHERE prNumber=$pr_num AND runId='$safe_run';" 2>>"$LOG")"
    if [ -n "$seen" ]; then
      return 1
    fi
    # Check cooldown
    local last_attempt
    last_attempt="$(sqlite3 "$DB" "SELECT MAX(attemptedAt) FROM ci_fix_seen WHERE prNumber=$pr_num;" 2>>"$LOG")"
    if [ -n "$last_attempt" ] && [ "$last_attempt" != "null" ]; then
      local last_ts now_ts
      last_ts=$(date -d "$last_attempt" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_attempt" +%s 2>/dev/null || echo 0)
      now_ts=$(date +%s)
      local cooldown_secs=$((CI_FIX_COOLDOWN_MINUTES * 60))
      if [ $((now_ts - last_ts)) -lt $cooldown_secs ]; then
        return 1
      fi
    fi
    return 0
}

# mark_ci_fix_attempted <repo> <prNumber> <runId>
mark_ci_fix_attempted() {
    local repo="$1" pr="$2" run="$3"
    local pr_num
    pr_num="$(sql_num "$pr")"
    [ -n "$pr_num" ] || return 0
    local safe_run
    safe_run="$(sql_escape "$run")"
    local now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sqlite3 "$DB" "INSERT OR REPLACE INTO ci_fix_seen (prNumber, runId, attemptedAt) VALUES ($pr_num, '$safe_run', '$now');" 2>>"$LOG"
}

# mark_ci_fix_failed_for_commit <repo> <prNumber> <head_sha> <branch> <reason>
# Records that a build-fix attempt failed for this specific commit. Until the
# PR head advances past this commit, the poller will skip queuing build-fix
# tasks for this PR (see is_ci_fix_failed_for_commit). Old rows for prior
# commits are preserved as a historical record and naturally fall out of
# relevance as the PR moves on.
mark_ci_fix_failed_for_commit() {
    local repo="$1" pr="$2" sha="$3" branch="$4" reason="$5"
    [ -n "$sha" ] || return 0
    local pr_num
    pr_num="$(sql_num "$pr")"
    [ -n "$pr_num" ] || return 0
    local safe_repo safe_branch safe_reason
    safe_repo="$(sql_escape "$repo")"
    safe_branch="$(sql_escape "$branch")"
    safe_reason="$(sql_escape "$reason")"
    local now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sqlite3 "$DB" "INSERT OR REPLACE INTO ci_fix_failed (repository, prNumber, head_sha, branch, reason, failed_at) VALUES ('$safe_repo', $pr_num, '$sha', '$safe_branch', '$safe_reason', '$now');" 2>>"$LOG"
    log "ci fix FAILED for $repo#$pr at commit $sha (branch=$branch): $reason — will not retry until head changes"
}

# is_ci_fix_failed_for_commit <repo> <prNumber> <head_sha> -> returns 0 if a
# failed attempt is already recorded for this exact commit (must skip), 1 if
# the commit is fresh and a fix attempt is allowed.
is_ci_fix_failed_for_commit() {
    local repo="$1" pr="$2" sha="$3"
    [ -n "$sha" ] && sqlite3 "$DB" "SELECT 1 FROM ci_fix_failed WHERE repository='$repo' AND prNumber=$pr AND head_sha='$sha' LIMIT 1;" 2>/dev/null | grep -q 1
}

has_unresolved_manul_tasks() {
    local repo="$1"
    local issue="$2"
    sqlite3 "$DB" "SELECT 1 FROM processed_comments WHERE repository='$repo' AND issueNumber=$issue AND commentId NOT LIKE 'ci_fix:%' AND status IN ('queued','running','failed') AND (status!='failed' OR attempts <= 2) LIMIT 1;" 2>>"$LOG"
}

# scan_failing_ci <repo> -> queues synthetic tasks for failing manul PRs
scan_failing_ci() {
    local repo="$1"
    [ "$CI_FIX_ENABLED" = "true" ] || return 0
    local prs_json
    # Scan all open PRs for failing CI (not just manul PRs)
    prs_json="$(gh pr list --repo "$repo" --limit 100 --json number,headRefName,baseRefName,title,url 2>>"$LOG" | jq -c '.[] | {number: .number, head: .headRefName, base: .baseRefName, title: .title, html_url: .url}' 2>>"$LOG" || true)"
    [ -n "$prs_json" ] || return 0
    local pr_count
    pr_count="$(printf '%s' "$prs_json" | jq 'length')"
    [ "$pr_count" -gt 0 ] || return 0
    log "scanning $pr_count open manul PR(s) on $repo for failing CI"
    local i=0
    while [ $i -lt "$pr_count" ]; do
      local pr
      pr="$(printf '%s' "$prs_json" | jq -c ".[$i]")"
      local pr_num pr_branch pr_title
      pr_num="$(printf '%s' "$pr" | jq -r '.number')"
      pr_branch="$(printf '%s' "$pr" | jq -r '.head')"
      pr_title="$(printf '%s' "$pr" | jq -r '.title')"
      # Skip build-fix if this PR already has unresolved manul tasks
      if has_unresolved_manul_tasks "$repo" "$pr_num"; then
        log "skipping CI fix for $repo#$pr_num — unresolved manul tasks present"
        i=$((i+1))
        continue
      fi
      # Get the PR's current head SHA — used as the per-commit skip key. If a
      # build-fix attempt already failed for THIS exact commit, do not queue
      # another one (the bot has proven it could not fix this build). The gate
      # lifts automatically the moment the PR head moves to a new commit.
      local pr_head_sha
      pr_head_sha="$(gh pr view "$pr_num" --repo "$repo" --json headRefOid --jq '.headRefOid // ""' 2>>"$LOG" || true)"
      if [ -n "$pr_head_sha" ] && is_ci_fix_failed_for_commit "$repo" "$pr_num" "$pr_head_sha"; then
        local prev_reason prev_at
        prev_reason="$(sqlite3 "$DB" "SELECT reason FROM ci_fix_failed WHERE repository='$repo' AND prNumber=$pr_num AND head_sha='$pr_head_sha' LIMIT 1;" 2>>"$LOG")"
        prev_at="$(sqlite3 "$DB" "SELECT failed_at FROM ci_fix_failed WHERE repository='$repo' AND prNumber=$pr_num AND head_sha='$pr_head_sha' LIMIT 1;" 2>>"$LOG")"
        log "skipping CI fix for $repo#$pr_num — build fix already FAILED for commit $pr_head_sha at ${prev_at:-?}: ${prev_reason:-no reason recorded}. Will retry once a new commit is pushed."
        i=$((i+1))
        continue
      fi
      # Get failing checks for this PR
      local checks_json
      checks_json="$(gh pr checks "$pr_num" --repo "$repo" --json name,state,completedAt,link 2>>"$LOG" | jq -c '[.[] | select(.state=="FAILURE" or .state=="ERROR")]' 2>>"$LOG" || true)"
      [ -n "$checks_json" ] || { i=$((i+1)); continue; }
      local failing_count
      failing_count="$(printf '%s' "$checks_json" | jq 'length')"
      [ "$failing_count" -gt 0 ] || { i=$((i+1)); continue; }
      log "found $failing_count failing check(s) on $repo#$pr_num ($pr_branch)"
      local j=0
      while [ $j -lt "$failing_count" ] && [ $j -lt "$CI_FIX_MAX_ATTEMPTS" ]; do
        local check
        check="$(printf '%s' "$checks_json" | jq -c ".[$j]")"
        local check_name check_state check_url
        check_name="$(printf '%s' "$check" | jq -r '.name')"
        check_state="$(printf '%s' "$check" | jq -r '.state')"
        check_url="$(printf '%s' "$check" | jq -r '.link // ""')"
        # Extract run ID from link if possible
        local run_id=""
        if printf '%s' "$check_url" | grep -q '/runs/'; then
          run_id="$(printf '%s' "$check_url" | sed -E 's|.*/runs/([0-9]+).*|\1|')"
        fi
        [ -n "$run_id" ] || run_id="check-$check_name-$(date +%s)"
        # Check if we already attempted this run
        if check_ci_fix_eligible "$repo" "$pr_num" "$run_id"; then
          # Create synthetic task for CI fix
          local prompt="CI build '$check_name' is failing on PR #$pr_num (branch: $pr_branch). Fix the failing build. PR: $(printf '%s' "$pr" | jq -r '.html_url')"
          local comment_id="ci_fix:$repo:$pr_num:$run_id"
          local created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          local esc_prompt
          esc_prompt="$(printf '%s' "$prompt" | sed "s/'/''/g")"
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      lease_expires="$(date -u -d "now + $LEASE_TIMEOUT seconds" +%Y-%m-%dT%H:%M:%SZ)"
          sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId) VALUES('$comment_id','$repo',$pr_num,'$(printf '%s' "$pr" | jq -r '.html_url')','manul-ci-fix','debugger','$esc_prompt','queued','$created_at','$now','$lease_expires','$(generate_conversation_id "$repo" "$pr_num" "pr-top-level")');" 2>>"$LOG"
          if [ "$(sqlite3 "$DB" "SELECT changes();" 2>>"$LOG")" -gt 0 ]; then
            NEW=$((NEW + 1))
            log "queued CI fix task for $repo#$pr_num run $run_id (check: $check_name)"
          fi
          mark_ci_fix_attempted "$repo" "$pr_num" "$run_id"
        fi
        j=$((j+1))
      done
      i=$((i+1))
    done
}
# === end ci fix helpers ===

NEW=0

# === Main polling logic (runs only when executed directly) ===
# Only run main logic when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [ "${#REPOS[@]}" -eq 0 ]; then
    echo 'MANUL_RESULT {"fire":false,"new":0,"pending":0,"repos":0}'
    exit 0
  fi

  for repo in "${REPOS[@]}"; do
    [ -n "$repo" ] || continue

    if ! acquire_repo_lock "$repo"; then
      continue
    fi
    repo_cleanup_lock=1

    # Batch-fetch issue/PR states for this repo to avoid per-comment API calls.
    # Populates: OPEN_ISSUES, CLOSED_ISSUES, OPEN_PRS, MERGED_PRS, CLOSED_PRS
    declare -A OPEN_ISSUES=() CLOSED_ISSUES=() OPEN_PRS=() MERGED_PRS=() CLOSED_PRS=()
    while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && OPEN_ISSUES["$n"]=1; done < <(gh issue list --repo "$repo" --limit 100 --json number --jq '.[].number' 2>>"$LOG" || true)
    while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && CLOSED_ISSUES["$n"]=1; done < <(gh issue list --repo "$repo" --limit 100 --state closed --json number --jq '.[].number' 2>>"$LOG" || true)
    while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && OPEN_PRS["$n"]=1; done < <(gh pr list --repo "$repo" --limit 100 --json number --jq '.[].number' 2>>"$LOG" || true)
    while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && MERGED_PRS["$n"]=1; done < <(gh pr list --repo "$repo" --limit 100 --state merged --json number --jq '.[] | select(.merged_at != null) | .number' 2>>"$LOG" || true)
    while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && CLOSED_PRS["$n"]=1; done < <(gh pr list --repo "$repo" --limit 100 --state closed --json number --jq '.[] | select(.merged_at == null) | .number' 2>>"$LOG" || true)

    # Auto-close conversations for merged PRs that have no remaining active tasks.
    if [ ${#MERGED_PRS[@]} -gt 0 ]; then
      merged_pr_ids=""
      for mp in "${!MERGED_PRS[@]}"; do
        [ -n "$merged_pr_ids" ] && merged_pr_ids="$merged_pr_ids,"
        merged_pr_ids="${merged_pr_ids}${mp}"
      done
      close_merged_pr_conversations "$merged_pr_ids"
    fi

    # Drain pending skip comments from a previous failed run (GitHub as primary frontend: comments are queued to skip-comments.log when feedback.sh fails after all retries, and retried here).
  skip_log="$MANUL_DIR/skip-comments.log"
  if [ -f "$skip_log" ]; then
    tmp_skip="${skip_log}.tmp"
    > "$tmp_skip"
    while IFS='|' read -r srepo sissue smsg stime; do
      [ -n "$srepo" ] || continue
      if "$MANUL_DIR/feedback.sh" "$srepo" "$sissue" "$smsg" 2>>"$LOG"; then
        log "delivered pending skip comment for $srepo#$sissue (queued at $stime)"
      else
        # Still failing — keep in queue for next poll
        printf '%s|%s|%s|%s\n' "$srepo" "$sissue" "$smsg" "$stime" >> "$tmp_skip"
        log "WARN: pending skip comment for $srepo#$sissue still failing, will retry next poll"
      fi
    done < "$skip_log"
    mv "$tmp_skip" "$skip_log"
  fi

    # Build JSON array of open PR numbers for routing decision in issue comment path.
    # PR conversation comments appear as issue comments in GitHub's API, so we need
    # to route them to REVIEW_FIX instead of IMPLEMENT.
    open_prs_json="[]"
    if [ ${#OPEN_PRS[@]} -gt 0 ]; then
      open_prs_json="$(printf '%s\n' "${!OPEN_PRS[@]}" | jq -R 'tonumber' | jq -s '.')"
    fi

# 1) Issue comments (PR conversation comments are issue comments too)
    while IFS= read -r obj; do
      [ -n "$obj" ] || continue
      id="$(jq -r '.id' <<<"$obj")"
      issue="$(jq -r '.issueNumber' <<<"$obj")"
      # Skip comments on closed issues and PR-conversation comments on
      # merged/closed PRs (PR review comments are handled in §2).
      [ -n "${CLOSED_ISSUES[$issue]:-}" ] && continue
      [ -n "${MERGED_PRS[$issue]:-}" ] && continue
      [ -n "${CLOSED_PRS[$issue]:-}" ] && continue
      url="$(jq -r '.url' <<<"$obj")"
      author="$(jq -r '.author' <<<"$obj")"
      created="$(jq -r '.created' <<<"$obj")"
      prompt="$(jq -r '.prompt' <<<"$obj")"
      agent="$(jq -r '.agent // ""' <<<"$obj")"
      action="$(jq -r '.action // ""' <<<"$obj")"
      [ -n "$prompt" ] || continue
      fullBody="$(jq -r '.fullBody // ""' <<<"$obj")"
      [ -n "$fullBody" ] || fullBody="$prompt"
      prompt="$fullBody"
      esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
      esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      # Generate conversation ID for issue comments
      conv_id="$(generate_conversation_id "$repo" "$issue" "issue")" || continue
      lease_expires="$(date -u -d "now + $LEASE_TIMEOUT seconds" +%Y-%m-%dT%H:%M:%SZ)"
      ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,action,prNumber,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','$action',$issue,'queued','$created','$now','$lease_expires','$(sql_escape "$conv_id")'); SELECT changes();" 2>>"$LOG")"
      if [ "${ins:-0}" -gt 0 ]; then
        NEW=$((NEW + 1))
        # Persist the trigger comment to conversation_messages BEFORE building
        # context, so the task's own prompt is included in history.
        # Use rawId/rawBody (no prefix, full body) to match what
        # persist_conversation_messages_for_repo will store later.
        local raw_id raw_body
        raw_id="$(jq -r '.rawId // $id' <<<"$obj")"
        raw_body="$(jq -r '.rawBody // .body // ""' <<<"$obj")"
        persist_conversation_message "$conv_id" "$repo" "$issue" "$raw_id" "$author" "$raw_body" "$url" "$created" "comment"
        sqlite3 "$DB" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$conv_id', '$(sql_escape "$repo")', $issue, '$url', NULL, 'OPEN', '$now', '$now');" 2>>"$LOG" || true
        ctx="$(build_conversation_context "$conv_id")"
        if [ -n "$ctx" ]; then
          esc_ctx="$(printf '%s' "$ctx" | sed "s/'/''/g")"
          sqlite3 "$DB" "UPDATE processed_comments SET context='$esc_ctx' WHERE commentId='$id';" 2>>"$LOG"
          log "context enriched for $id on $repo#$issue (conversation history)"
        fi
        log "queued $id on $repo#$issue (agent=${agent:-default})"
      fi
    done < <(gh api --paginate "repos/$repo/issues/comments?per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" --argjson open_prs "$open_prs_json" '
      .[] | select(.created_at >= $base) | select(.body | contains($trig)) | select((.body // "") | contains($sig) | not) | select(.user.login as $u | $allowed | index($u)) |
      (.body | split("\n")) as $lines
      | ([range(0; $lines|length) | select($lines[.] | contains($trig))][0]) as $idx
      | ($lines[$idx] | split($trig) | .[1:] | join($trig) | sub("^[ \t]+"; "")) as $rest0
      | (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else $rest0 end) as $rest
      | ($rest | split(" ")[0]) as $tok
      | (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
      | (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt_no_agent
      | (if $tok == "review-fix" then {action: "REVIEW_FIX", prompt: ($rest | ltrimstr("review-fix") | sub("^[ \t]+"; ""))}
         elif $tok == "fix-impl" then {action: "IMPLEMENT", prompt: ($rest | ltrimstr("fix-impl") | sub("^[ \t]+"; ""))}
         elif $tok == "run" then {action: "IMPLEMENT", prompt: ($rest | ltrimstr("run") | sub("^[ \t]+"; ""))}
         elif $agent != "" then {action: "IMPLEMENT", prompt: $prompt_no_agent}
         else {action: null, prompt: $rest}
         end) as $actx
      | (.html_url | capture("(?:issues|pull)/(?<n>[0-9]+)").n | tonumber) as $issue_num
      | (if $actx.action != null then $actx.action
          elif ($open_prs | index($issue_num)) then "REVIEW_FIX"
          else "IMPLEMENT"
          end) as $action
      | {
        id: ("issue:" + (.id|tostring)),
        rawId: (.id|tostring),
        rawBody: .body,
        repo: $repo,
        author: .user.login,
        created: .created_at,
        url: .html_url,
        issueNumber: $issue_num,
        agent: $agent,
        action: $action,
        prompt: $actx.prompt,
        fullBody: (.body | sub($trig; "") | sub("^[ \t]+"; ""))
      }' 2>>"$LOG" || true)

    # 1b) Issue bodies (new OPEN issues carrying the trigger in the description) — state=open skips closed issues
    # state=open ensures manul does NOT process closed issues.
    while IFS= read -r obj; do
      [ -n "$obj" ] || continue
      id="$(jq -r '.id' <<<"$obj")"
      issue="$(jq -r '.issueNumber' <<<"$obj")"
      url="$(jq -r '.url' <<<"$obj")"
      author="$(jq -r '.author' <<<"$obj")"
      created="$(jq -r '.created' <<<"$obj")"
      prompt="$(jq -r '.prompt' <<<"$obj")"
      agent="$(jq -r '.agent // ""' <<<"$obj")"
      action="$(jq -r '.action // ""' <<<"$obj")"
      [ -n "$prompt" ] || continue
      esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
      esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      conv_id="$(generate_conversation_id "$repo" "$issue" "issue")" || continue
      lease_expires="$(date -u -d "now + $LEASE_TIMEOUT seconds" +%Y-%m-%dT%H:%M:%SZ)"
      ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,action,prNumber,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','$action',$issue,'queued','$created','$now','$lease_expires','$(sql_escape "$conv_id")'); SELECT changes();" 2>>"$LOG")"
      if [ "${ins:-0}" -gt 0 ]; then
        NEW=$((NEW + 1))
        # Ensure conversation exists for this issue body
        sqlite3 "$DB" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$conv_id', '$(sql_escape "$repo")', $issue, '$url', NULL, 'OPEN', '$now', '$now');" 2>>"$LOG" || true
        log "queued $id on $repo#$issue (issue body, agent=${agent:-default}, action=${action:-IMPLEMENT})"
      fi
    done < <(gh api --paginate "repos/$repo/issues?state=open&since=$BASELINE&per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" '
      .[] | select(.pull_request | not) | select(.created_at >= $base) | select(.body // "" | contains($trig)) | select((.body // "") | contains($sig) | not) | select(.user.login as $u | $allowed | index($u)) |
      (.body | split("\n")) as $lines
      | ([range(0; $lines|length) | select($lines[.] | contains($trig))][0]) as $idx
      | ($lines[$idx] | split($trig) | .[1:] | join($trig) | sub("^[ \t]+"; "")) as $rest0
      | (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else $rest0 end) as $rest
      | ($rest | split(" ")[0]) as $tok
      | (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
      | (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt_no_agent
      | (if $tok == "review-fix" then {action: "REVIEW_FIX", prompt: ($rest | ltrimstr("review-fix") | sub("^[ \t]+"; ""))}
         elif $tok == "fix-impl" then {action: "IMPLEMENT", prompt: ($rest | ltrimstr("fix-impl") | sub("^[ \t]+"; ""))}
         elif $tok == "run" then {action: "IMPLEMENT", prompt: ($rest | ltrimstr("run") | sub("^[ \t]+"; ""))}
         elif $agent != "" then {action: "IMPLEMENT", prompt: $prompt_no_agent}
         else {action: null, prompt: $rest}
         end) as $actx
      | (if $actx.action != null then $actx.action else "IMPLEMENT" end) as $action
      | {
        id: ("issuebody:" + (.id|tostring)),
        repo: $repo,
        author: .user.login,
        created: .created_at,
        url: .html_url,
        issueNumber: .number,
        agent: $agent,
        action: $action,
        prompt: $actx.prompt
      }' 2>>"$LOG" || true)

    # 2) PR review comments
    # Only process review comments on OPEN PRs. The GitHub pulls/comments API
    # returns comments from ALL PRs (including merged/closed), so we filter by
    # PR state here. This also catches reply comments (in_reply_to_id != null)
    # inside review threads — the old logic only tracked top-level comments and
    # silently dropped /manul replies.
    # OPEN_PRS already populated above (batch fetch for the whole repo) — reuse it.
    # Fetch all review comments once, then filter by open PRs.
    review_comments="$(gh api --paginate "repos/$repo/pulls/comments?per_page=100" 2>>"$LOG" || echo "[]")"

    # Build a lookup of PRs to their comment counts for conversation ID determination
    declare -A PR_COMMENT_COUNTS=()
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      pr_num="$(jq -r '.html_url | capture("pull/(?<n>[0-9]+)").n' <<<"$line")"
      [ -n "$pr_num" ] && PR_COMMENT_COUNTS["$pr_num"]=$(( ${PR_COMMENT_COUNTS["$pr_num"]:-0} + 1 ))
    done < <(printf '%s\n' "$review_comments" | jq -c '.[]' 2>/dev/null || true)

    while IFS= read -r obj; do
      [ -n "$obj" ] || continue
      id="$(jq -r '.id' <<<"$obj")"
      pr_num="$(jq -r '.issueNumber' <<<"$obj")"
      # Skip if not an open PR
      [ -n "${OPEN_PRS[$pr_num]:-}" ] || continue
      # Skip review comments on merged/closed PRs
      [ -n "${MERGED_PRS[$pr_num]:-}" ] && continue
      [ -n "${CLOSED_PRS[$pr_num]:-}" ] && continue
      # Replies are part of a review thread and must be processed; the
      # conversation ID below points them to their root thread.
      url="$(jq -r '.url' <<<"$obj")"
      author="$(jq -r '.author' <<<"$obj")"
      created="$(jq -r '.created' <<<"$obj")"
      prompt="$(jq -r '.prompt' <<<"$obj")"
      agent="$(jq -r '.agent // ""' <<<"$obj")"
      action="$(jq -r '.action // ""' <<<"$obj")"
      [ -n "$prompt" ] || continue
      fullBody="$(jq -r '.fullBody // ""' <<<"$obj")"
      [ -n "$fullBody" ] || fullBody="$prompt"
      prompt="$fullBody"
      cpath="$(jq -r '.path // ""' <<<"$obj")"
      cline="$(jq -r '.line // ""' <<<"$obj")"
      chunk="$(jq -r '.diffHunk // ""' <<<"$obj")"
      esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
      esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      # Determine conversation ID based on thread structure only
      raw_id="$(jq -r '.rawId // .id' <<<"$obj")"
      raw_id="${raw_id#review:}"
      reply_to="$(jq -r '.in_reply_to_id // empty' <<<"$obj")"
      if [ -n "$reply_to" ]; then
        root_id="$(get_review_thread_root_id "$review_comments" "$raw_id")"
      else
        root_id="$raw_id"
      fi
      conv_id="$(generate_conversation_id "$repo" "$pr_num" "review-thread" "$root_id")" || continue
      lease_expires="$(date -u -d "now + $LEASE_TIMEOUT seconds" +%Y-%m-%dT%H:%M:%SZ)"
      ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,action,prNumber,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId) VALUES('$id','$repo',$pr_num,'$url','$author','$esc_a','$esc','$action',$pr_num,'queued','$created','$now','$lease_expires','$(sql_escape "$conv_id")'); SELECT changes();" 2>>"$LOG")"
      if [ "${ins:-0}" -gt 0 ]; then
        NEW=$((NEW + 1))
        # Persist the trigger review comment to conversation_messages BEFORE
        # building context, so the task's own prompt is included in history.
        # Use rawId/rawBody (no prefix, full body) to match what
        # persist_conversation_messages_for_repo will store later.
        local raw_id raw_body
        raw_id="$(jq -r '.rawId // $id' <<<"$obj")"
        raw_body="$(jq -r '.rawBody // .body // ""' <<<"$obj")"
        persist_conversation_message "$conv_id" "$repo" "$pr_num" "$raw_id" "$author" "$raw_body" "$url" "$created" "review-comment"
        sqlite3 "$DB" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$conv_id', '$(sql_escape "$repo")', $pr_num, '$url', $pr_num, 'OPEN', '$now', '$now');" 2>>"$LOG" || true
        ctx="$(build_conversation_context "$conv_id")"
        if [ -n "$ctx" ]; then
          esc_ctx="$(printf '%s' "$ctx" | sed "s/'/''/g")"
          sqlite3 "$DB" "UPDATE processed_comments SET context='$esc_ctx' WHERE commentId='$id';" 2>>"$LOG"
          log "context enriched for $id on $repo#$pr_num (conversation history)"
        fi
        # GitHub control protocol integration: process review events
        if [ -f "$MANUL_DIR/manul-pr-review.sh" ] && [ -n "$prompt" ]; then
          review_id="${id#review:}"
          # Link this review to the PR's conversation using the thread-aware
          # conv_id computed above; do NOT overwrite it with pr-top-level.
          if [ -n "$conv_id" ]; then
            sqlite3 "$DB" "INSERT OR IGNORE INTO conversation_links(conversationId, repo, prNumber, commentId, linkType, createdAt) VALUES('$conv_id', '$(sql_escape "$repo")', $pr_num, '$(sql_escape "$id")', 'review', '$now');" 2>>"$LOG" || true
          fi
        fi
        log "queued $id on $repo#$pr_num (agent=${agent:-default})"
      fi
    done < <(gh api --paginate "repos/$repo/pulls/comments?per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" '
      .[] | select(.created_at >= $base) | select(.body | contains($trig)) | select((.body // "") | contains($sig) | not) | select(.user.login as $u | $allowed | index($u)) |
      (.body | split("\n")) as $lines
      | ([range(0; $lines|length) | select($lines[.] | contains($trig))][0]) as $idx
      | ($lines[$idx] | split($trig) | .[1:] | join($trig) | sub("^[ \t]+"; "")) as $rest0
      | (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else $rest0 end) as $rest
      | ($rest | split(" ")[0]) as $tok
      | (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
      | (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt_no_agent
      | (if $tok == "review-fix" then {action: "REVIEW_FIX", prompt: ($rest | ltrimstr("review-fix") | sub("^[ \t]+"; ""))}
         elif $tok == "fix-impl" then {action: "IMPLEMENT", prompt: ($rest | ltrimstr("fix-impl") | sub("^[ \t]+"; ""))}
         elif $tok == "run" then {action: "IMPLEMENT", prompt: ($rest | ltrimstr("run") | sub("^[ \t]+"; ""))}
         elif $agent != "" then {action: "IMPLEMENT", prompt: $prompt_no_agent}
         else {action: null, prompt: $rest}
         end) as $actx
      | (if $actx.action != null then $actx.action else "REVIEW_FIX" end) as $action
      | {
        id: ("review:" + (.id|tostring)),
        rawId: (.id|tostring),
        rawBody: .body,
        repo: $repo,
        author: .user.login,
        created: .created_at,
        url: .html_url,
        issueNumber: (.html_url | capture("pull/(?<n>[0-9]+)").n | tonumber),
        agent: $agent,
        action: $action,
        prompt: $actx.prompt,
        fullBody: (.body | sub($trig; "") | sub("^[ \t]+"; "")),
        path: (.path // ""),
        line: ((.line // .original_line // "") | tostring),
        diffHunk: (.diff_hunk // ""),
        in_reply_to_id: (.in_reply_to_id // null),
        isResolved: (.in_reply_to_id // null | . != null)
      }' 2>>"$LOG" || true)

    # 2b) PR review events (REQUEST_CHANGES -> REVIEW_FIX tasks)
    # The pulls/comments API returns individual comments, not review events.
    # We need the reviews API to get the review state (APPROVED, CHANGES_REQUESTED, etc.)
    if [ -f "$MANUL_DIR/manul-pr-review.sh" ]; then
      # Fetch open PRs and their reviews
      while IFS= read -r pr_obj; do
        [ -n "$pr_obj" ] || continue
        pr_num="$(jq -r '.number' <<<"$pr_obj")"
        [ -n "$pr_num" ] || continue
        [ -n "${OPEN_PRS[$pr_num]:-}" ] || continue

        # Fetch reviews for this PR
        reviews_json="$(gh api "repos/$repo/pulls/$pr_num/reviews?per_page=100" 2>>"$LOG" || echo '[]')"
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        while IFS= read -r review; do
          [ -n "$review" ] || continue
          review_id="$(jq -r '.id // empty' <<<"$review")"
          [ -n "$review_id" ] || continue
          review_state="$(jq -r '.state // empty' <<<"$review")"
          review_body="$(jq -r '.body // ""' <<<"$review")"
          review_author="$(jq -r '.user.login // "unknown"' <<<"$review")"
          review_created="$(jq -r '.submitted_at // empty' <<<"$review")"
          [ -n "$review_created" ] || review_created="$now"

           # Only create REVIEW_FIX tasks for REQUEST_CHANGES
           if [ "$review_state" = "CHANGES_REQUESTED" ]; then
             log "processing REQUEST_CHANGES review $review_id on $repo#$pr_num"
             # Ensure a conversation exists for this PR; create one if missing
             # IMPORTANT: Do NOT overwrite an existing review-thread conversation.
             # Only create pr-top-level conversation if no conversation exists at all.
             existing_conv="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='$(sql_escape "$repo")' AND activePrNumber=$pr_num AND status != 'COMPLETED' LIMIT 1;" 2>/dev/null || echo "")"
             if [ -z "$existing_conv" ]; then
               local pr_url
               pr_url="$(gh pr view "$pr_num" --repo "$repo" --json url --jq '.url' 2>/dev/null)" || pr_url="https://github.com/$repo/pull/$pr_num"
               [ -n "$pr_url" ] || pr_url="https://github.com/$repo/pull/$pr_num"
               new_conv_id="$(generate_conversation_id "$repo" "$pr_num" "pr-top-level")"
               sqlite3 "$DB" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$new_conv_id', '$(sql_escape "$repo")', $pr_num, '$pr_url', $pr_num, 'OPEN', '$now', '$now');" 2>>"$LOG"
               log "auto-created conversation $new_conv_id for $repo#$pr_num"
             fi
            if "$MANUL_DIR/manul-pr-review.sh" handle \
              --repo "$repo" \
              --pr-number "$pr_num" \
              --review-id "$review_id" \
              --review-state "REQUEST_CHANGES" \
              --body "$review_body" \
              --author "$review_author" \
              --created "$review_created" \
              --json >>"$LOG" 2>&1; then
              log "review $review_id on $repo#$pr_num processed successfully"
            else
              log "WARN: failed to process review $review_id on $repo#$pr_num"
            fi
          elif [ "$review_state" = "APPROVED" ]; then
            log "received APPROVE on $repo#$pr_num (no fix task created)"
          else
            log "received $review_state review on $repo#$pr_num (no action)"
          fi
        done < <(echo "$reviews_json" | jq -c '.[]' 2>/dev/null)
      done < <(gh pr list --repo "$repo" --state open --json number,headRefName,baseRefName,title,url 2>>"$LOG" | jq -c '.[]' 2>>"$LOG" || true)
    fi

    # Persist non-trigger comments as conversation history for all issues/PRs
    # that had trigger comments this poll. This ensures the daemon has full
    # thread context even for messages that didn't contain /manul.
    persist_conversation_messages_for_repo "$repo"

    # 3) Drain pending skip comments from a previous failed run (GitHub as
    # primary frontend: comments are queued to skip-comments.log when feedback.sh
    # fails after all retries, and retried here).
    skip_log="$MANUL_DIR/skip-comments.log"
    if [ -f "$skip_log" ]; then
      tmp_skip="${skip_log}.tmp"
      > "$tmp_skip"
      while IFS='|' read -r srepo sissue smsg stime; do
        [ -n "$srepo" ] || continue
        if "$MANUL_DIR/feedback.sh" "$srepo" "$sissue" "$smsg" 2>>"$LOG"; then
          log "delivered pending skip comment for $srepo#$sissue (queued at $stime)"
        else
          # Still failing — keep in queue for next poll
          printf '%s|%s|%s|%s\n' "$srepo" "$sissue" "$smsg" "$stime" >> "$tmp_skip"
          log "WARN: pending skip comment for $srepo#$sissue still failing, will retry next poll"
        fi
      done < "$skip_log"
      mv "$tmp_skip" "$skip_log"
    fi

    # Scan for failing CI on manul PRs
    scan_failing_ci "$repo"
  done

  if [ "${repo_cleanup_lock:-0}" -eq 1 ]; then
    for repo in "${REPOS[@]}"; do
      release_repo_lock "$repo"
    done
  fi

  PENDING="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued';" 2>/dev/null || echo 0)"

  LOCKED=0
  if [ -f "$LOCK" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$LOCK") ))
    [ "$age" -lt "$LOCK_TTL_SECONDS" ] && LOCKED=1
  fi

  if { [ "$NEW" -gt 0 ] || [ "$PENDING" -gt 0 ]; } && [ "$LOCKED" -eq 0 ]; then
    echo "MANUL_RESULT {\"fire\":true,\"new\":$NEW,\"pending\":$PENDING}"
  elif [ "$NEW" -gt 0 ] || [ "$PENDING" -gt 0 ]; then
    echo "MANUL_RESULT {\"fire\":false,\"new\":$NEW,\"pending\":$PENDING,\"locked\":true}"
  else
    echo "MANUL_RESULT {\"fire\":false,\"new\":0,\"pending\":0}"
  fi

fi