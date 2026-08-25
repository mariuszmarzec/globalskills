#!/usr/bin/bash
# manul-poll.sh — GitHub /manul trigger poller for OpenClaw cron.
#
# Scans configured repos for issue comments + PR review comments containing the
# trigger command, queues unprocessed ones in SQLite, rebuilds queue.json and
# prints a single MANUL_RESULT line for the cron trigger wrapper.
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
#   queue.json       — pending work for the orchestrator agent turn
#   lock             — orchestrator run lock (fresh lock => don't fire)
set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="${MANUL_DIR}/config.json"
DB="${MANUL_DIR}/manul.db"
QUEUE_JSON="${MANUL_DIR}/queue.json"
LOCK="${MANUL_DIR}/lock"
LOG="${MANUL_DIR}/poll.log"
LOCK_TTL_SECONDS="${MANUL_LOCK_TTL_SECONDS:-1800}"
REPO_LOCK_DIR="${MANUL_DIR}/repo-locks"
REPO_LOCK_TTL="${MANUL_REPO_LOCK_TTL_SECONDS:-1800}"
mkdir -p "$REPO_LOCK_DIR" 2>/dev/null || true

log() { echo "[$(date -Is)] $*" >>"$LOG"; }
fail() { echo "MANUL_RESULT {\"fire\":false,\"error\":\"$1\"}"; exit 0; }

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
    running_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE repository='$repo' AND status='running';" 2>/dev/null || echo 0)"
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
ALLOWED_JSON="$(jq -c '.allowedUsers // [.repositories[0] | split("/")[0]]' "$CONFIG" 2>/dev/null)"
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

if [ $# -gt 0 ]; then
  REPOS=("$@")
else
  mapfile -t REPOS < <(jq -r '.repositories[]?' "$CONFIG" 2>/dev/null)
fi
if [ "${#REPOS[@]}" -eq 0 ]; then
  echo 'MANUL_RESULT {"fire":false,"new":0,"pending":0,"repos":0}'
  exit 0
fi

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
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);" 2>>"$LOG"

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
  local seen
  seen="$(sqlite3 "$DB" "SELECT 1 FROM ci_fix_seen WHERE prNumber=$pr AND runId='$run';" 2>>"$LOG")"
  if [ -n "$seen" ]; then
    return 1
  fi
  # Check cooldown
  local last_attempt
  last_attempt="$(sqlite3 "$DB" "SELECT MAX(attemptedAt) FROM ci_fix_seen WHERE prNumber=$pr;" 2>>"$LOG")"
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
  local now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT OR REPLACE INTO ci_fix_seen (prNumber, runId, attemptedAt) VALUES ($pr, '$run', '$now');" 2>>"$LOG"
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
  local now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local esc_branch esc_reason
  esc_branch="$(printf '%s' "$branch" | sed "s/'/''/g")"
  esc_reason="$(printf '%s' "$reason" | sed "s/'/''/g")"
  sqlite3 "$DB" "INSERT OR REPLACE INTO ci_fix_failed (repository, prNumber, head_sha, branch, reason, failed_at) VALUES ('$repo', $pr, '$sha', '$esc_branch', '$esc_reason', '$now');" 2>>"$LOG"
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
  prs_json="$(gh api --paginate "repos/$repo/pulls?state=open&per_page=100" 2>>"$LOG" | jq -c '[.[] | {number: .number, head: .head.ref, base: .base.ref, title: .title, html_url: .html_url}]' 2>>"$LOG")"
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
    pr_head_sha="$(gh pr view "$pr_num" --repo "$repo" --json headRefOid --jq '.headRefOid // ""' 2>>"$LOG")"
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
    checks_json="$(gh pr checks "$pr_num" --repo "$repo" --json name,state,completedAt,link 2>>"$LOG" | jq -c '[.[] | select(.state=="FAILURE" or .state=="ERROR")]' 2>>"$LOG")"
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
        sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt) VALUES('$comment_id','$repo',$pr_num,'$(printf '%s' "$pr" | jq -r '.html_url')','manul-ci-fix','debugger','$esc_prompt','queued','$created_at');" 2>>"$LOG"
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
for repo in "${REPOS[@]}"; do
  [ -n "$repo" ] || continue

  if ! acquire_repo_lock "$repo"; then
    continue
  fi
  repo_cleanup_lock=1

  # Batch-fetch issue/PR states for this repo to avoid per-comment API calls.
  # Populates: OPEN_ISSUES, CLOSED_ISSUES, OPEN_PRS, MERGED_PRS, CLOSED_PRS
  declare -A OPEN_ISSUES CLOSED_ISSUES OPEN_PRS MERGED_PRS CLOSED_PRS
  while read -r n; do [ -n "$n" ] && OPEN_ISSUES["$n"]=1; done < <(gh api --paginate "repos/$repo/issues?state=open&per_page=100" --jq '.[].number' 2>>"$LOG")
  while read -r n; do [ -n "$n" ] && CLOSED_ISSUES["$n"]=1; done < <(gh api --paginate "repos/$repo/issues?state=closed&per_page=100" --jq '.[].number' 2>>"$LOG")
  while read -r n; do [ -n "$n" ] && OPEN_PRS["$n"]=1; done < <(gh api --paginate "repos/$repo/pulls?state=open&per_page=100" --jq '.[].number' 2>>"$LOG")
  while read -r n; do [ -n "$n" ] && MERGED_PRS["$n"]=1; done < <(gh api --paginate "repos/$repo/pulls?state=closed&per_page=100" --jq '.[] | select(.merged_at != null) | .number' 2>>"$LOG")
  while read -r n; do [ -n "$n" ] && CLOSED_PRS["$n"]=1; done < <(gh api --paginate "repos/$repo/pulls?state=closed&per_page=100" --jq '.[] | select(.merged_at == null) | .number' 2>>"$LOG")

  # Drain pending skip comments from a previous failed run (GitHub as primary frontend: comments are queued to skip-comments.log when feedback.sh fails after all retries, and retried here).
skip_log="$MANUL_DIR/skip-comments.log"
if [ -f "$skip_log" ]; then
  tmp_skip="${skip_log}.tmp"
  > "$tmp_skip"
  while IFS='|' read -r srepo sissue smsg stime; do
    [ -n "$srepo" ] || continue
    if /mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh "$srepo" "$sissue" "$smsg" 2>>"$LOG"; then
      log "delivered pending skip comment for $srepo#$sissue (queued at $stime)"
    else
      # Still failing — keep in queue for next poll
      printf '%s|%s|%s|%s\n' "$srepo" "$sissue" "$smsg" "$stime" >> "$tmp_skip"
      log "WARN: pending skip comment for $srepo#$sissue still failing, will retry next poll"
    fi
  done < "$skip_log"
  mv "$tmp_skip" "$skip_log"
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
    [ -n "$prompt" ] || continue
    fullBody="$(jq -r '.fullBody // ""' <<<"$obj")"
    [ -n "$fullBody" ] || fullBody="$prompt"
    prompt="$fullBody"
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
    ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt,issueState,prState) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','queued','$created','${CLOSED_ISSUES[$issue]:-open}','${OPEN_PRS[$issue]:-}'); SELECT changes();" 2>>"$LOG")"
    if [ "${ins:-0}" -gt 0 ]; then
      NEW=$((NEW + 1))
      ctx="$(build_issue_context "$repo" "$issue")"
      if [ -n "$ctx" ]; then
        esc_ctx="$(printf '%s' "$ctx" | sed "s/'/''/g")"
        sqlite3 "$DB" "UPDATE processed_comments SET context='$esc_ctx' WHERE commentId='$id';" 2>>"$LOG"
        log "context enriched for $id on $repo#$issue (parent issue)"
      fi
      log "queued $id on $repo#$issue (agent=${agent:-default})"
    fi
  done < <(gh api --paginate "repos/$repo/issues/comments?per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" '
    .[] | select(.created_at >= $base) | select(.body | contains($trig)) | select((.body // "") | contains($sig) | not) | select(.user.login as $u | $allowed | index($u)) |
    (.body | split("\n")) as $lines
    | ([range(0; $lines|length) | select($lines[.] | contains($trig))][0]) as $idx
    | ($lines[$idx] | split($trig) | .[1:] | join($trig) | sub("^[ \t]+"; "")) as $rest0
    | (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else $rest0 end) as $rest
    | ($rest | split(" ")[0]) as $tok
    | (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
    | (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt
    | {
      id: ("issue:" + (.id|tostring)),
      repo: $repo,
      author: .user.login,
      created: .created_at,
      url: .html_url,
      issueNumber: (.issue_url | capture("issues/(?<n>[0-9]+)$").n | tonumber),
      agent: $agent,
      prompt: $prompt,
      fullBody: (.body | sub($trig; ""))
    }')

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
    [ -n "$prompt" ] || continue
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
    ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt,issueState) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','queued','$created','open'); SELECT changes();" 2>>"$LOG")"
    if [ "${ins:-0}" -gt 0 ]; then
      NEW=$((NEW + 1))
      log "queued $id on $repo#$issue (issue body, agent=${agent:-default})"
    fi
  done < <(gh api --paginate "repos/$repo/issues?state=open&since=$BASELINE&per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" '
    .[] | select(.pull_request | not) | select(.created_at >= $base) | select(.body // "" | contains($trig)) | select((.body // "") | contains($sig) | not) | select(.user.login as $u | $allowed | index($u)) |
    (.body | split("\n")) as $lines
    | ([range(0; $lines|length) | select($lines[.] | contains($trig))][0]) as $idx
    | ($lines[$idx] | split($trig) | .[1:] | join($trig) | sub("^[ \t]+"; "")) as $rest0
    | (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else $rest0 end) as $rest
    | ($rest | split(" ")[0]) as $tok
    | (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
    | (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt
    | {
      id: ("issuebody:" + (.id|tostring)),
      repo: $repo,
      author: .user.login,
      created: .created_at,
      url: .html_url,
      issueNumber: .number,
      agent: $agent,
      prompt: $prompt
    }')

  # 2) PR review comments
  # Only process review comments on OPEN PRs. The GitHub pulls/comments API
  # returns comments from ALL PRs (including merged/closed), so we filter by
  # PR state here. This also catches reply comments (in_reply_to_id != null)
  # inside review threads — the old logic only tracked top-level comments and
  # silently dropped /manul replies.
  # OPEN_PRS already populated above (batch fetch for the whole repo) — reuse it.
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    id="$(jq -r '.id' <<<"$obj")"
    issue="$(jq -r '.issueNumber' <<<"$obj")"
    # Skip review comments on closed/merged PRs and resolved threads.
    [ -n "${OPEN_PRS[$issue]:-}" ] || continue
    [ -n "${MERGED_PRS[$issue]:-}" ] && continue
    [ -n "${CLOSED_PRS[$issue]:-}" ] && continue
    [ "$(jq -r '.isResolved // false' <<<"$obj")" = "true" ] && continue
    url="$(jq -r '.url' <<<"$obj")"
    author="$(jq -r '.author' <<<"$obj")"
    created="$(jq -r '.created' <<<"$obj")"
    prompt="$(jq -r '.prompt' <<<"$obj")"
    agent="$(jq -r '.agent // ""' <<<"$obj")"
    [ -n "$prompt" ] || continue
    fullBody="$(jq -r '.fullBody // ""' <<<"$obj")"
    [ -n "$fullBody" ] || fullBody="$prompt"
    prompt="$fullBody"
    cpath="$(jq -r '.path // ""' <<<"$obj")"
    cline="$(jq -r '.line // ""' <<<"$obj")"
    chunk="$(jq -r '.diffHunk // ""' <<<"$obj")"
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
    pr_state="$(jq -r '.state // ""' <<<"$obj")"
    is_res="$(jq -r '.isResolved // false' <<<"$obj")"
    ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt,prState,isResolved) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','queued','$created','${pr_state:-open}',$is_res); SELECT changes();" 2>>"$LOG")"
    if [ "${ins:-0}" -gt 0 ]; then
      NEW=$((NEW + 1))
      ctx="$(build_review_context "$repo" "$issue" "$cpath" "$cline" "$chunk")"
      if [ -n "$ctx" ]; then
        esc_ctx="$(printf '%s' "$ctx" | sed "s/'/''/g")"
        sqlite3 "$DB" "UPDATE processed_comments SET context='$esc_ctx' WHERE commentId='$id';" 2>>"$LOG"
        log "context enriched for $id on $repo#$issue (PR + linked issues)"
      fi
      log "queued $id on $repo#$issue (agent=${agent:-default})"
    fi
  done < <(gh api --paginate "repos/$repo/pulls/comments?per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" '
    .[] | select(.created_at >= $base) | select(.body | contains($trig)) | select((.body // "") | contains($sig) | not) | select(.user.login as $u | $allowed | index($u)) |
    (.body | split("\n")) as $lines
    | ([range(0; $lines|length) | select($lines[.] | contains($trig))][0]) as $idx
    | ($lines[$idx] | split($trig) | .[1:] | join($trig) | sub("^[ \t]+"; "")) as $rest0
    | (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else $rest0 end) as $rest
    | ($rest | split(" ")[0]) as $tok
    | (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
    | (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt
    | {
      id: ("review:" + (.id|tostring)),
      repo: $repo,
      author: .user.login,
      created: .created_at,
      url: .html_url,
      issueNumber: (.html_url | capture("pull/(?<n>[0-9]+)").n | tonumber),
      agent: $agent,
      prompt: $prompt,
      fullBody: (.body | sub($trig; "")),
      path: (.path // ""),
      line: ((.line // .original_line // "") | tostring),
      diffHunk: (.diff_hunk // ""),
      isResolved: (.in_reply_to_id // null | . != null)
    }')

  # 3) Drain pending skip comments from a previous failed run (GitHub as
  # primary frontend: comments are queued to skip-comments.log when feedback.sh
  # fails after all retries, and retried here).
  skip_log="$MANUL_DIR/skip-comments.log"
  if [ -f "$skip_log" ]; then
    tmp_skip="${skip_log}.tmp"
    > "$tmp_skip"
    while IFS='|' read -r srepo sissue smsg stime; do
      [ -n "$srepo" ] || continue
      if /mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh "$srepo" "$sissue" "$smsg" 2>>"$LOG"; then
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

# Recover stuck tasks: if a task has been `running` for longer than 2x TTL,
# reset it to `queued` so it can be retried. This handles crashes where the
# worker died without clearing the lock / updating DB.
STUCK_THRESHOLD=$(( REPO_LOCK_TTL * 2 ))
sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL WHERE status='running' AND (strftime('%s','now') - strftime('%s', COALESCE(processedAt, createdAt))) > $STUCK_THRESHOLD;" 2>>"$LOG"
STUCK_RESET="$(sqlite3 "$DB" "SELECT changes();" 2>/dev/null || echo 0)"
if [ "${STUCK_RESET:-0}" -gt 0 ]; then
  log "recovered $STUCK_RESET stuck running task(s) older than ${STUCK_THRESHOLD}s"
fi

# Reaper: remove queued tasks for closed issues / merged-closed PRs
sqlite3 "$DB" "DELETE FROM processed_comments WHERE status='queued' AND ( (issueState='closed') OR (prState IN ('merged','closed')) );" 2>>"$LOG"
REAPER="$(sqlite3 "$DB" "SELECT changes();" 2>/dev/null || echo 0)"
if [ "${REAPER:-0}" -gt 0 ]; then
  log "reaped $REAPER stale queued task(s) for closed issues/PRs"
fi

# Double-check: re-verify open state of issues/PRs for ALL queued tasks.
# Between scan and now, some may have been closed/merged. If so, mark them
# as skipped (status=failed) and post a "skipped — already closed" comment.
verify_queued_open() {
  local repo="$1" issue="$2" commentId="$3" commentUrl="$4" isPr="$5"
  local state_json state
  if [ "$isPr" = "true" ]; then
    state_json="$(gh pr view "$issue" --repo "$repo" --json state 2>>"$LOG" | jq -r '.state // ""')"
  else
    state_json="$(gh issue view "$issue" --repo "$repo" --json state 2>>"$LOG" | jq -r '.state // ""')"
  fi
  state="$state_json"
  if [ "$state" = "closed" ] || [ "$state" = "merged" ]; then
    # Mark as failed so it won't be re-queued
    sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$commentId';" 2>>"$LOG"
    # Post skip comment using feedback.sh with retries
    # If all retries fail, persist to a pending-comments file for retry on next poll
    post_skip_comment() {
      local repo="$1" issue="$2" msg="$3" attempt=1 max=3 delay=2 skip_log="$MANUL_DIR/skip-comments.log"
      while [ $attempt -le $max ]; do
        if /mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh "$repo" "$issue" "$msg" 2>>"$LOG"; then
          return 0
        fi
        log "WARN: feedback.sh failed for $repo#$issue (attempt $attempt/$max), retrying in ${delay}s..."
        sleep $delay
        attempt=$((attempt + 1))
        delay=$((delay * 2))
      done
      log "WARN: feedback.sh FAILED after $max attempts for $repo#$issue — queuing comment for next poll"
      printf '%s|%s|%s|%s\n' "$repo" "$issue" "$msg" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$skip_log"
      return 0
    }
    post_skip_comment "$repo" "$issue" "⏭️ Skipping — the ${isPr:+PR }issue was already $state before the task could be processed."
    log "skipped task $commentId on $repo#$issue — ${isPr:+PR }issue is $state"
    return 1
  fi
  return 0
}

# Run verification on all currently queued tasks
sqlite3 "$DB" -separator '|' "SELECT commentId, repository, issueNumber, commentUrl, prState FROM processed_comments WHERE status='queued';" 2>>"$LOG" | while IFS='|' read -r cid repo issue url prstate; do
  [ -n "$cid" ] || continue
  if [ -n "$prstate" ] && [ "$prstate" != "" ]; then
    # It was a PR (review comment or PR conversation)
    verify_queued_open "$repo" "$issue" "$cid" "$url" "true"
  else
    # It was an issue (issue comment or issue body)
    verify_queued_open "$repo" "$issue" "$cid" "$url" "false"
  fi
done

# Rebuild queue.json from queued rows (failed rows with attempts below max re-queue)
ESCALATION_ROUNDS="${MANUL_ESCALATION_ROUNDS:-3}"
sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL WHERE status='failed' AND attempts <= $ESCALATION_ROUNDS;" 2>>"$LOG"
QUEUE_TMP="${QUEUE_JSON}.tmp"
sqlite3 "$DB" "SELECT json_group_array(json_object('commentId',commentId,'repository',repository,'issueNumber',issueNumber,'commentUrl',commentUrl,'author',author,'agent',agent,'prompt',prompt,'context',context,'attempts',attempts,'ciFix',CASE WHEN commentId LIKE 'ci_fix:%' THEN 1 ELSE 0 END)) FROM (SELECT commentId,repository,issueNumber,commentUrl,author,agent,prompt,context,attempts FROM processed_comments WHERE status='queued' ORDER BY createdAt);" 2>>"$LOG" >"$QUEUE_TMP"
if ! jq -e . "$QUEUE_TMP" >/dev/null 2>&1; then
  echo '[]' >"$QUEUE_TMP"
fi
mv "$QUEUE_TMP" "$QUEUE_JSON"
PENDING="$(jq 'length' "$QUEUE_JSON" 2>/dev/null || echo 0)"

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
