---
name: manul-github-bot
description: Setup, operate, and reinstall the manul GitHub command bot (OpenClaw + gh). Manul reacts to `/manul` in issue/PR comments, implements the task on a `manul/*` branch, pushes, optionally opens a PR, and replies with comments signed "manul 🐈". Use when installing manul on a (new) machine, changing its config, or debugging it.
---

# Manul GitHub Bot 🐈

Manul (kot stepowy, Pallas's cat) is a GitHub command bot driven by OpenClaw.
It watches configured repositories, reacts to the trigger `/manul` in issue
bodies, issue comments, and PR review comments, and implements the requested
task: dedicated branch `<type>/manul/<issue>-<slug>` → commit → push → optional
PR → feedback comments on the issue. Every comment/PR manul writes is signed
`— manul 🐈`
(identity: **manul** on GitHub, **OpenClaw** in the console).

```
        /\_/\
       ( o.o )   manul 🐈 — GitHub command bot
        > ^ <
```

## Architecture

```
manul-daemon.sh (setsid background loop, no systemd needed)
   │ every pollInterval (default 60s)
   ▼
poll.sh ── gh api: issue bodies + issue comments + PR review comments
   │         (created_at >= baseline) + contains trigger
   ▼
SQLite manul.db (processed_comments: queued→running→done|failed, meta.baseline)
   │ rebuild queue.json
   ▼
fire:true? ──► openclaw agent --agent manul --message-file orchestrator.prompt.md \
                  --session-key manul-worker  (headless, timeout -k 60)
                        │
                        ▼
manul agent (isolated persona: /mnt/f/ubuntu-workspace/.openclaw/workspace-manul, restricted tools,
             own session store under /mnt/f/ubuntu-workspace/.openclaw/agents/manul/sessions)
   orchestrator: per task → mark running → post "🤖 Running..." →
                 sessions_spawn subagent (worker) → wait (sessions_yield)
                        │
                        ▼
worker: clone repo → branch <type>/manul/<issue>-<slug> → implement → tests → commit
        (Co-authored-by trailer) → push → gh pr create (if autoCreatePr)
                        │
                        ▼
orchestrator: parse MANUL_RESULT → post ✅ Done / ❌ Failed (English only)
              → update DB (done/failed)
```

Dispatch is synchronous (daemon waits for the agent turn), so runs never
overlap; `lock` is a backstop with 30 min TTL.

## Files (canonical source lives here — copy from this skill)

| Path | Purpose |
|---|---|
| `/mnt/f/ubuntu-workspace/.openclaw/manul/config.json` | enabled, pollInterval, trigger, agents[], autoCreatePr, allowedUsers[], repositories[] |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/poll.sh` | poller: scan + dedupe + queue rebuild; enriches tasks with full comment body + context (PR body, linked issues, file/line/diff for review comments; parent issue for issue comments) |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh` | post a signed comment (strips literal `/manul`) |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/manul-daemon.sh` | start/stop/status/run-once wrapper around the loop |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/orchestrator.prompt.md` | prompt for the headless orchestrator agent turn |
| `/mnt/f/ubuntu-workspace/.openclaw/workspace-manul/` | isolated agent workspace (AGENTS.md, SOUL.md) |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/manul.db` | SQLite state (created on first poll) |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/queue.json` | pending tasks (rebuilt each poll) |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/poll.log`, `daemon.log` | logs |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/lock` | run lock (TTL 1800s) |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/work/<owner-repo>/` | git clones used by workers |
| `/mnt/f/ubuntu-workspace/.openclaw/manul/e2e-watch.sh` | E2E test helper (polls until PR/done) |

### Installation

Run the installer or use the skill directly. After installation, add a
convenience alias for `manul-status` in your shell rc:

```bash
alias manul-status='$HOME/.openclaw/manul/manul-status.sh'
```

### config.json

```json
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "agents": [
    "architect",
    "coder",
    "coder-cheap",
    "coder-strong",
    "coder-expert",
    "reviewer",
    "reviewer-expert",
    "debugger",
    "debugger-expert",
    "researcher",
    "tester",
    "security",
    "performance",
    "refactorer"
  ],
  "autoCreatePr": true,
  "allowedUsers": ["mariuszmarzec"],
  "repositories": [
    "mariuszmarzec/fiteo",
    "mariuszmarzec/shoppingListGenerator",
    "mariuszmarzec/QuickMVI",
    "mariuszmarzec/todo"
  ],
  "ciFix": {
    "enabled": true,
    "maxAttemptsPerRun": 2,
    "cooldownMinutes": 60
  }
}
```

* `allowedUsers` — GitHub logins allowed to invoke manul (others are ignored).
  Default when missing: the owner of the first repository.
* `agents` — known role agent names. The parser sets the task's `agent` field
  only when the first token after the trigger on the trigger line matches one
  of these exactly. Missing key → fallback to the default list above.

### Role agents (OpenClaw-native, no opencode)

The role agents (`coder`, `reviewer`, `debugger`, …) are defined as OpenClaw
agents in the gateway config (`agents.list`) — id, model, skills, tool
allowlist (reviewer/researcher/security/performance are read-only: no
write/edit/apply_patch) and `subagents.allowAgents`. The manul agent entry has
`subagents.allowAgents` listing all role ids so the orchestrator can spawn them
via `sessions_spawn(agentId=<role>)`. Models follow the `agent-orchestration`
skill tiers (CHEAP/NORMAL/STRONG/EXPERT). Do NOT shell out to `opencode` —
the role logic lives in the OpenClaw agent config + this skill.

### Watched repositories

Context for workers when implementing tasks:

| Repository | What it is |
|---|---|
| `mariuszmarzec/fiteo` | Backend for the todo, cheatday and fiteoApp applications |
| `mariuszmarzec/shoppingListGenerator` | Shopping list generator — adds tasks to the todo app via API call and adds items to the shopping list in Listonic |
| `mariuszmarzec/QuickMVI` | MVI store library, used by fiteoApp and the todo app |
| `mariuszmarzec/todo` | Todo list app (todoApp) — uses the fiteo backend |
| `mariuszmarzec/fiteoApp` | Workout/training app — uses the fiteo backend |
| `mariuszmarzec/cheatDay` | Cheat day app — uses the fiteo backend |
| `mariuszmarzec/caracal-rag` | RAG service for the fiteo backend — research + architecture doc (Kotlin exploration) on `feature/manul/6-caracal-rag-kotlin` / PR #1 |

### poll.sh

```bash
#!/usr/bin/env bash
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

log() { echo "[$(date -Is)] $*" >>"$LOG"; }
fail() { echo "MANUL_RESULT {\"fire\":false,\"error\":\"$1\"}"; exit 0; }

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
# Enriches queued tasks with the surrounding GitHub context so workers get the
# WHOLE picture, not just the trigger-line snippet:
#   - review comments -> PR (title/body/state) + every issue linked in the PR
#     body (e.g. the task issue) + comment path/line/diffHunk
#   - issue comments  -> parent issue (title/body)
# Context is stored in the `context` column (JSON) and shipped via queue.json;
# the orchestrator passes it to the worker verbatim.
declare -A CTX_PR_CACHE CTX_ISSUE_CACHE

# extract_issue_refs <text> <default-repo> -> lines "<owner/repo> <number>"
# Finds issue references of the forms:
#   https://github.com/<owner>/<repo>/issues/<n>
#   <owner>/<repo>#<n>
#   #<n>                       (same repo)
extract_issue_refs() {
  local text="$1" repo="$2"
  printf '%s' "$text" | grep -oE 'https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+' | awk -v repo="$repo" '
    /^http/ { split($0, a, "/"); print a[4] "/" a[5], a[7] }
    /#/ && !/^http/ && index($0, "/") { split($0, a, "#"); print a[1], a[2] }
    /^#/ { sub(/^#/, ""); print repo, $0 }
  ' | sort -u
}

# fetch_issue_ctx <owner/repo> <number> -> {"number":n,"title":...,"body":...} (cached)
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

# build_review_context <repo> <pr> <path> <line> <diffHunk> -> JSON
# {pr:{number,title,state,body}, linkedIssues:[{number,title,body}], comment:{path,line,diffHunk}}
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

# build_issue_context <repo> <issueNumber> -> JSON {issue:{number,title,body}}
build_issue_context() {
  local repo="$1" n="$2" issue_json
  issue_json="$(fetch_issue_ctx "$repo" "$n")"
  if [ -n "$issue_json" ]; then
    printf '%s' "$issue_json" | jq -c '{issue:.}'
  fi
}
# === end context enrichment helpers ===

NEW=0
for repo in "${REPOS[@]}"; do
  [ -n "$repo" ] || continue

  # 1) Issue comments (PR conversation comments are issue comments too)
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
    # fullBody = whole comment with the trigger marker removed (fixes the old
    # truncation where only the trigger-line rest was kept as the prompt)
    fullBody="$(jq -r '.fullBody // ""' <<<"$obj")"
    [ -n "$fullBody" ] || fullBody="$prompt"
    prompt="$fullBody"
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
    ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','queued','$created'); SELECT changes();" 2>>"$LOG")"
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

  # 1b) Issue bodies (new issues carrying the trigger in the description)
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
    ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','queued','$created'); SELECT changes();" 2>>"$LOG")"
    if [ "${ins:-0}" -gt 0 ]; then
      NEW=$((NEW + 1))
      log "queued $id on $repo#$issue (issue body, agent=${agent:-default})"
    fi
  done < <(gh api --paginate "repos/$repo/issues?state=all&since=$BASELINE&per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" '
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
    # fullBody = whole review comment with the trigger marker removed; path,
    # line and diffHunk travel along so the worker gets the exact code spot
    fullBody="$(jq -r '.fullBody // ""' <<<"$obj")"
    [ -n "$fullBody" ] || fullBody="$prompt"
    prompt="$fullBody"
    cpath="$(jq -r '.path // ""' <<<"$obj")"
    cline="$(jq -r '.line // ""' <<<"$obj")"
    chunk="$(jq -r '.diffHunk // ""' <<<"$obj")"
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
    ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','queued','$created'); SELECT changes();" 2>>"$LOG")"
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
      diffHunk: (.diff_hunk // "")
    }')
done

# Rebuild queue.json from queued rows (failed rows with attempts below max re-queue)
# Escalation: a failed task goes back to queued (attempts incremented by the
# orchestrator before marking failed) — the daemon re-dispatches it and the
# orchestrator picks a stronger agent next round. Max ESCALATION_ROUNDS; beyond
# that the task stays failed and is not re-queued.
ESCALATION_ROUNDS="${MANUL_ESCALATION_ROUNDS:-2}"
sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL WHERE status='failed' AND attempts <= $ESCALATION_ROUNDS;" 2>>"$LOG"
QUEUE_TMP="${QUEUE_JSON}.tmp"
sqlite3 "$DB" "SELECT json_group_array(json_object('commentId',commentId,'repository',repository,'issueNumber',issueNumber,'commentUrl',commentUrl,'author',author,'agent',agent,'prompt',prompt,'context',context,'attempts',attempts)) FROM (SELECT commentId,repository,issueNumber,commentUrl,author,agent,prompt,context,attempts FROM processed_comments WHERE status='queued' ORDER BY createdAt);" 2>>"$LOG" >"$QUEUE_TMP"
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

```

### feedback.sh

```bash
#!/usr/bin/env bash
# feedback.sh <repo> <issueNumber> <message> [--in-reply-to <reviewCommentId>]
# Post a signed manul comment. With --in-reply-to the comment is posted as a
# reply inside the PR review thread (pulls/<n>/comments with in_reply_to);
# otherwise it goes to the issue/PR conversation (issues/<n>/comments).
# Note: the documented endpoint pulls/comments/<id>/replies returns 404 on
# github.com (as of 2026-08) — in_reply_to on pulls/<n>/comments is the
# reliable way to reply in-thread.
# Strips any literal "/manul" from the message (self-trigger protection) and
# signs with "— manul 🐈". Prints the created comment URL.
set -euo pipefail
repo="$1"
issue="$2"
msg="$3"
reply_to=""
if [ "${4:-}" = "--in-reply-to" ]; then
  reply_to="${5:-}"
fi
msg="$(printf '%s' "$msg" | sed -E 's@(^|[[:space:]])/manul([[:space:]]|$)@\1manul\2@g')"
# Idempotent signing: strip any trailing "— manul 🐈" the caller already
# included (defense against a double signature), then sign exactly once.
while [[ "$msg" =~ ([[:space:]]*—[[:space:]]*manul[[:space:]]*🐈[[:space:]]*)$ ]]; do
  msg="${msg%"${BASH_REMATCH[1]}"}"
done
signed="${msg}"$'\n\n— manul 🐈'
if [ -n "$reply_to" ]; then
  jq -nc --arg body "$signed" --argjson in_reply_to "$reply_to" '{body: $body, in_reply_to: $in_reply_to}' | gh api --method POST "repos/$repo/pulls/$issue/comments" --input - -q '.html_url'
else
  jq -nc --arg body "$signed" '{body: $body}' | gh api "repos/$repo/issues/$issue/comments" --input - -q '.html_url'
fi
```

### manul-daemon.sh

```bash
#!/usr/bin/env bash
# manul-daemon.sh — background poll loop for the manul GitHub bot.
#
# Usage:
#   manul-daemon.sh start      — start the poll loop (setsid, survives gateway restarts)
#   manul-daemon.sh stop       — stop it
#   manul-daemon.sh status     — is it running?
#   manul-daemon.sh run-once   — single poll + dispatch (for testing)
#
# Loop: every $MANUL_INTERVAL (default from config pollInterval, else 60s) run
# poll.sh; when it reports fire:true, dispatch one headless agent turn via
# `openclaw agent --agent manul`. Dispatch is synchronous, so runs never
# overlap; the lock file is a backstop.
set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.openclaw/manul}"
CONFIG="${MANUL_DIR}/config.json"
POLL="$MANUL_DIR/poll.sh"
PROMPT_FILE="$MANUL_DIR/orchestrator.prompt.md"
PID_FILE="$MANUL_DIR/daemon.pid"
LOG="$MANUL_DIR/daemon.log"
LOCK="$MANUL_DIR/lock"
CFG_INTERVAL="$(jq -r '.pollInterval // empty' "$CONFIG" 2>/dev/null)"
INTERVAL="${MANUL_INTERVAL:-${CFG_INTERVAL:-60}}"
AGENT_TIMEOUT="${MANUL_AGENT_TIMEOUT:-1800}"   # seconds for the agent turn
OPENCLAW_BIN="$(command -v openclaw)"

log() { echo "[$(date -Is)] $*" >>"$LOG"; }

start() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "already running (pid $(cat "$PID_FILE"))"
    return 0
  fi
  setsid nohup "$0" loop >>"$LOG" 2>&1 &
  echo $! >"$PID_FILE"
  echo "manul daemon started (pid $(cat "$PID_FILE"), interval ${INTERVAL}s)"
}

stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "not running"
    return 0
  fi
  pid="$(cat "$PID_FILE")"
  kill "$pid" 2>/dev/null
  rm -f "$PID_FILE"
  echo "manul daemon stopped (pid $pid)"
}

status() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "running (pid $(cat "$PID_FILE"))"
  else
    echo "not running"
  fi
}

run_once() {
  out="$("$POLL")"
  echo "$out"
  if printf '%s' "$out" | grep -q '"fire":true'; then
    log "dispatch: $out"
    [ -f "$LOCK" ] || date +%s >"$LOCK"
    timeout -k 60 "$AGENT_TIMEOUT" "$OPENCLAW_BIN" agent --agent manul \
      --message-file "$PROMPT_FILE" --session-key manul-worker >>"$LOG" 2>&1
    rc=$?
    echo "[$(date -Is)] agent turn finished rc=$rc" >>"$LOG"
    rm -f "$LOCK"
  fi
}

loop() {
  log "daemon loop started (interval ${INTERVAL}s)"
  while true; do
    run_once
    sleep "$INTERVAL"
  done
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  run-once) run_once ;;
  loop) loop ;;
  *) echo "usage: $0 start|stop|status|run-once" >&2; exit 2 ;;
esac
```

### orchestrator.prompt.md

```markdown
You are the manul bot orchestrator. Manul = GitHub command bot: it reacts to comments containing `/manul` by implementing the requested task on a branch and reporting back with GitHub comments. You are triggered by the poller daemon when new tasks exist.

**THE QUEUE IS THE SOURCE OF TRUTH.** If a task is in queue.json, you MUST process it in this very turn: mark it running, post the 🤖 Running comment, spawn the worker, wait for it, post the result. Do NOT investigate history, do NOT check GitHub for previous attempts, do NOT wonder whether the task was already handled — previous attempts may have failed, that's exactly why the task is queued again. If the queue has tasks, your job is to execute, not to audit.

You run as the isolated agent `manul` (workspace `/mnt/f/ubuntu-workspace/.openclaw/workspace-manul`, session `manul-worker`). Your own workspace is minimal — ALL bot state lives under `/home/marzec/.openclaw/manul/`. Never read or write the main agent's workspace (`/home/marzec/.openclaw/workspace`, `/mnt/f/ubuntu-workspace/.openclaw/workspace`).

## Step 0 — Read the queue

Read `/home/marzec/.openclaw/manul/queue.json` (array of tasks):
`[{"commentId": "...", "repository": "owner/repo", "issueNumber": 12, "commentUrl": "...", "author": "...", "agent": "coder", "prompt": "...", "context": "...", "attempts": 0}]`

- `agent` is the role agent explicitly requested on the trigger line (e.g. `/manul reviewer check the diff` → `reviewer`). The parser only sets it for exact matches against the known list; empty string means "no agent requested" → use the default `coder`.
- `prompt` is the FULL comment/issue text with the trigger marker removed (never truncated).
- `context` (optional JSON string, enriched by the poller at queue time):
  - review comments: `{"pr":{"number":..,"title":..,"state":..,"body":..}, "linkedIssues":[{"number":..,"title":..,"body":..}], "comment":{"path":..,"line":..,"diffHunk":..}}` — the PR body describes the task, `linkedIssues` are the issues referenced in the PR body (e.g. the task issue).
  - issue comments: `{"issue":{"number":..,"title":..,"body":..}}` — the parent issue.
  Pass `context` to the worker VERBATIM whenever present.

- If the file is missing or the array is empty → reply `NO_REPLY` and stop.
- DB: `/home/marzec/.openclaw/manul/manul.db` (sqlite3). Task statuses: `queued` → `running` → `done` | `failed`.
- Lock: the daemon holds `/home/marzec/.openclaw/manul/lock` while you run — it guarantees only one dispatch at a time. Do **not** check or remove it; just proceed with the queue.

## Step 0.5 — Leftover recovery (ALWAYS, before Step 1)

Crashed turns (gateway restart, machine reboot, timeout kill) leave tasks stuck in `running`. The daemon only queues tasks with status `queued`, so stranded `running` tasks are never retried automatically. At the start of EVERY turn:

1. `sqlite3 /home/marzec/.openclaw/manul/manul.db "SELECT commentId, createdAt FROM processed_comments WHERE status='running';"`
2. If any rows come back, they are leftovers from a crashed turn. Reset each:
   `sqlite3 /home/marzec/.openclaw/manul/manul.db "UPDATE processed_comments SET status='queued', processedAt=NULL WHERE commentId='<commentId>';"`
3. The daemon's next poll (≤60s) will rebuild the queue with full task details and dispatch them. Mention recovered leftovers in your final summary.
   If the queue.json you already read in Step 0 contained tasks, process those normally — do NOT double-process a task you just reset (it is not in the current queue.json yet).

**Important:** if Step 0.5 finds NO `running` rows (the usual case), move straight to Step 1. Do not spend time "investigating" — the queue in Step 0 is what you process.

## Step 1 — Process each task

For every task in queue.json — **process it NOW, in this turn, without investigating anything else**:

**Escalation context:** the task carries `attempts` (how many times a worker
has already run on it and failed). `attempts=0` → first try. Each failed run
increments `attempts`; the daemon re-queues failed tasks automatically as long
as `attempts <= 2`. Your job: pick the right agent tier for the CURRENT
attempt (see step 2) and, on failure, decide whether to escalate or give up.

1. Mark running:
   `sqlite3 /home/marzec/.openclaw/manul/manul.db "UPDATE processed_comments SET status='running' WHERE commentId='<commentId>';"`

2. Resolve the agent (read the known list from config if needed:
   `jq -r '.agents[]' /home/marzec/.openclaw/manul/config.json`):
   - If the task already has an explicit `agent` (from the trigger) AND
     `attempts == 0`, use it.
   - Otherwise pick by escalation tier based on `attempts`:
       attempts 0 → default `coder` (NORMAL tier) — or the explicit agent if set
       attempts 1 → escalate: `coder-strong` (STRONG) if the role is coding
                    (reviewer/debugger/etc. → their -expert variant); keep the
                    same role family, just one tier higher
       attempts 2 → escalate again: `coder-expert` (EXPERT)
   - Escalation map (role → attempts1 → attempts2):
       coder        → coder-strong  → coder-expert
       debugger     → debugger-expert
       reviewer     → reviewer-expert
       (other roles: same family, -expert at attempts≥1; if no expert variant
        exists, keep the role but note the escalation in the Running comment)
   - `agent` empty → default agent is `coder`. BUT first check the prompt's
     first word: if it is a plausible (case-insensitive, close) spelling of a
     known agent name, the user probably meant an explicit agent — post ONE
     comment that both informs and runs:
     `🤖 Running... Unknown agent '<first-word>' — using the default coder. Known agents: <comma-separated>. Accepted the task: <prompt, first 200 chars>`
     and proceed with `coder`.
   - Otherwise (no agent requested) → default `coder`.

3. Post the running comment (English), using the helper:
   - explicit agent: `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "🤖 Running... (agent: <agent>) Accepted the task: <prompt, first 200 chars>"`
   - default: `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "🤖 Running... Accepted the task: <prompt, first 200 chars>"`
   - escalation round: `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "🤖 Running... (attempt <n+1>, escalated to <agent>) Accepted the task: <prompt, first 200 chars>"`

   **feedback.sh signs automatically — NEVER include `— manul 🐈` in the message you pass to it** (it would be added a second time).

   **If the task came from a PR review comment** (commentId starts with `review:`,
   e.g. `review:3740554181`): reply INSIDE the review thread instead of the PR
   conversation — pass `--in-reply-to <numeric-id-after-review:>`:
   `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "🤖 Running... Accepted the task: <prompt, first 200 chars>" --in-reply-to 3740554181`

   If the prompt is vague or does not describe a concrete task (e.g. it just
   says "do it", "fix this"), fetch the issue context first and
   use it as the task description:
   `gh issue view <issueNumber> --repo <repository>` — pass the issue
   title + body to the worker as the actual task. If the task carries
   `context.issue` (JSON from the queue), use THAT instead of fetching.

   **If the task came from a PR review comment** (commentId starts with `review:`,
   e.g. `review:3740554181`): the worker needs the complete context — the
   comment, the code spot, the PR, AND the issues the PR links to:
   - **If the task has a `context` field** (enriched by the poller): pass it to
     the worker VERBATIM — it already contains the full PR body, every issue
     linked in the PR body (title+body, e.g. the task issue), and the comment
     path/line/diffHunk. Do NOT re-fetch anything.
   - **Legacy tasks without `context`**: fetch it yourself:
     - `gh api repos/<repository>/pulls/comments/<review-comment-id>` (gets diff_hunk, path, body, line)
     - `gh pr view <issueNumber> --repo <repository>` (gets PR title, body, state)
     - **ALWAYS also fetch every issue linked in the PR body** (regex `issues/(\d+)` / `#(\d+)` / `owner/repo#\d+`): `gh issue view <n> --repo <owner/repo> --json number,title,body` and include each title+body.
   Pass ALL of this (full comment body, file/diff, PR body, linked issues) as part of the subagent task description.

3.5. CI priority check (before spawning):
   - If this task relates to a PR (review comment, or issueNumber is a PR number), inspect the queue.json from Step 0 for OTHER tasks with the same `repository` + `issueNumber` but different `commentId`.
   - If there ARE other tasks for the same PR → set `skipCiFix=true` for this dispatch.
   - If there are NO other tasks → set `skipCiFix=false`.
   - When writing the subagent brief: include the CI Build / Check Inspection instruction ONLY if `skipCiFix=false`. If `skipCiFix=true`, omit that bullet entirely.

4. Spawn ONE subagent with `sessions_spawn` (mode=run, runtime=subagent, taskName=`manul-<issueNumber>-<agent>`). Use `agentId=<agent>` (the resolved role agent, e.g. `coder`, `reviewer`, `debugger`) — its system prompt/model come from the OpenClaw agent config. Pass absolute `cwd` = `/home/marzec/.openclaw/manul/work/...` (NEVER use `~`). The subagent brief (write it explicitly):

   ---
   You are a manul worker running as the `<agent>` role agent (your role's
   system prompt and model come from the OpenClaw agent config). Fix a task
   requested via GitHub comment. The manul contract below still governs
   everything GitHub-related:
   - Repository: `<repository>` (use `gh` CLI; auth is already set up)
   - Task (from comment `<commentUrl>` by `<author>`): `<prompt>`
     If the task carries a `context` field, append it verbatim:
     `- Context (enriched by the poller): <context JSON — PR body, linked issues, comment path/line/diff>`
   - Work dir: `/home/marzec/.openclaw/manul/work/<repository-slashed-to-dash>` — `gh repo clone <repository> <dir>` if missing, else `cd` + `git fetch origin` + checkout the default branch (resolve via `gh repo view <repository> --json defaultBranchRef -q .defaultBranchRef.name`).
   - Create branch `<type>/manul/<issueNumber>-<short-kebab-slug>` where `<type>` is `feature` for new functionality/changes/improvements and `bugfix` for bug fixes (judge from the task; when in doubt use `feature`). `<issueNumber>` is the issue/PR number the task came from. Slug from the prompt, max ~40 chars, alnum+dash. Examples: `feature/manul/12-update-ktor`, `bugfix/manul/3-fix-crash-on-empty-input`.
   - **Plans/proposals/analyses go in a COMMENT, never in a PR with a markdown file.** If the task is a plan, proposal, analysis, or „don't code yet“ request: DO NOT create a branch/PR/md file. Instead write the plan as a reply comment on the issue (use `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "<plan>"`) and include a short summary in the ✅ Done comment. The ONLY exception: the task EXPLICITLY asks for a markdown file / document in the repo (e.g. „add docs/plan.md“) — then do the PR as usual.
   - Implement the minimal fix for the task. Run the relevant tests/build (check for README/Makefile/package.json/gradle etc.). If tests fail after a genuine best effort, report that honestly.
   - **CI Build / Check Inspection (skipCiFix=false only):** If this task relates to an existing PR (or after pushing a new branch/PR), check GitHub Actions or CI check status using `gh pr checks` or `gh run list --branch <branch>`. If any CI checks or builds are failing (`failure`), investigate the failure logs using `gh run view <run-id> --log-failed` (or `gh pr checks`), fix the root cause in the code, commit, and push so CI passes.
   - Commit with a conventional message (e.g. `fix: <summary>`). NEVER use `--author`, never change git author config. Append the trailer line `Co-authored-by: AI Agent <agent@ai.local>` to every AI-created commit (ai-commit-attribution skill). Push to origin.
   - Resolve the correct PR base branch: use the branch that the new feature branch was created from, NOT the repository default branch. If the branch was explicitly created from a named base branch, use that branch. If `develop` exists and the branch was based on it, use `develop`. Otherwise use the repository default branch. You can inspect this with `git branch --show-current` before branching, or from branch history.
   - If `/home/marzec/.openclaw/manul/config.json` has `autoCreatePr: true` → create the PR with a MEANINGFUL description (never a stub like "Task from comment"): write the body to `/tmp/manul-pr-body.md` and run `gh pr create --base <parent-branch> --title "manul: <short summary>" --body-file /tmp/manul-pr-body.md`; otherwise just push the branch.
   - **Resolved review threads:** When processing review comments, ignore comments whose root review thread is already resolved. Only act on unresolved threads; resolved threads are not actionable and should not trigger new work.     The description MUST cover:
       * Task: what was requested (one line + comment URL)
       * Changes: concrete summary of what the diff does (not a copy of the commit message)
       * Verification: what you ran (tests/build) and the result
     Language: match the repository's language — detect it from the README/code
     comments; code repos default to English. End with the signature `— manul 🐈`.
     Example:
       ## Task
       Update the project to the latest ktor (3.5.2) — [issue #4](<commentUrl>)

       ## Changes
       - Bumped ktor to 3.5.2 (and kotlin, if required) in buildSrc/Dependency.kt
       - Added gradle.properties with JVM heap settings

       ## Verification
       - `./gradlew build` passes

       — manul 🐈
   - Do NOT post any GitHub comments yourself, do NOT force-push.
   - Skip if an open PR or a branch matching `feature/manul/<issueNumber>-*` or `bugfix/manul/<issueNumber>-*` already exists for this task (report as already-exists).
   - End your final reply with EXACTLY ONE line starting `MANUL_RESULT ` in the form:
     `MANUL_RESULT status=ok branch=<branch> commit=<sha> pr_url=<url-or-> summary=<one line>`
     or `MANUL_RESULT status=failed reason=<short reason>`
   ---

5. When the subagent finishes: parse its `MANUL_RESULT` line.
   - ok → `UPDATE processed_comments SET status='done', processedAt='<now>' WHERE commentId='<commentId>';` then post (in-thread if review comment, same rule as step 3):
     `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "✅ Done

Summary: <summary>
Branch: <branch>
Commit: <commit>
PR: <pr_url>"` (omit PR line if none)

     Same rule: the message must NOT contain the signature — feedback.sh appends `— manul 🐈` itself.
   - failed → decide: escalate or give up.
     * Read the task's current attempts: `sqlite3 ... "SELECT attempts FROM processed_comments WHERE commentId='<commentId>';"`
     * If `attempts < 2` (more escalation rounds allowed):
       `UPDATE processed_comments SET status='failed', attempts=attempts+1, processedAt='<now>' WHERE commentId='<commentId>';`
       then post a short comment: `❌ Failed (attempt <n+1>) — retrying with a stronger agent.

Reason: <reason>`
       The daemon's next poll re-queues it and the next turn escalates.
       Do NOT post the full ❌ Failed summary yet — the task is not finished.
     * If `attempts >= 2` (no rounds left): `UPDATE ... SET status='failed', attempts=attempts+1 ...` then post the honest final: `❌ Failed

Reason: <reason>`
       and do NOT re-queue (the daemon's re-queue guard stops at `attempts > 2`).
   - If you spawned subagents, use `sessions_yield` and wait for completion events before finishing.

## Step 2 — Finish

- Reply with a compact summary of what was done (task → status → PR URL).

## Hard rules

- Never include the literal trigger `/manul` in any comment you post (self-trigger protection). Note: the poller ALSO ignores any comment signed with `— manul 🐈` (feedback.sh signs all bot comments), so a path like `docs/manul-…` inside a bot comment no longer re-triggers — but keep the no-trigger rule anyway.
- NEVER create a PR targeting `develop` (or any non-default branch). The PR base is always the repository's default branch (e.g. `main`, `master`) — resolve it via `gh repo view <repository> --json defaultBranchRef -q .defaultBranchRef.name`.
- All GitHub comments (🤖 Running…, ✅ Done) are written in English; PR descriptions are written in English (code repos); code/technical identifiers stay as-is. Manul never writes Polish on GitHub.
- Never force-push. Never touch branches other than `feature/manul/*` and `bugfix/manul/*`.
- Plans/proposals/analyses are always posted as comments on the issue — never as PRs with markdown files — unless the task explicitly requests a markdown file in the repo.
- If anything is ambiguous in a task, do your best with a minimal, safe change and note assumptions in the summary.

```

## Step 0 — Read the queue

Read `/home/marzec/.openclaw/manul/queue.json` (array of tasks):
`[{"commentId": "...", "repository": "owner/repo", "issueNumber": 12, "commentUrl": "...", "author": "...", "agent": "coder", "prompt": "...", "context": "...", "attempts": 0}]`

- `agent` is the role agent explicitly requested on the trigger line (e.g. `/manul reviewer check the diff` → `reviewer`). The parser only sets it for exact matches against the known list; empty string means "no agent requested" → use the default `coder`.
- `prompt` is the FULL comment/issue text with the trigger marker removed (never truncated).
- `context` (optional JSON string, enriched by the poller at queue time):
  - review comments: `{"pr":{"number":..,"title":..,"state":..,"body":..}, "linkedIssues":[{"number":..,"title":..,"body":..}], "comment":{"path":..,"line":..,"diffHunk":..}}` — the PR body describes the task, `linkedIssues` are the issues referenced in the PR body (e.g. the task issue).
  - issue comments: `{"issue":{"number":..,"title":..,"body":..}}` — the parent issue.
  Pass `context` to the worker VERBATIM whenever present.

- If the file is missing or the array is empty → reply `NO_REPLY` and stop.
- DB: `/home/marzec/.openclaw/manul/manul.db` (sqlite3). Task statuses: `queued` → `running` → `done` | `failed`.
- Lock: the daemon holds `/home/marzec/.openclaw/manul/lock` while you run — it guarantees only one dispatch at a time. Do **not** check or remove it; just proceed with the queue.

## Step 0.5 — Leftover recovery (ALWAYS, before Step 1)

Crashed turns (gateway restart, machine reboot, timeout kill) leave tasks stuck in `running`. The daemon only queues tasks with status `queued`, so stranded `running` tasks are never retried automatically. At the start of EVERY turn:

1. `sqlite3 /home/marzec/.openclaw/manul/manul.db "SELECT commentId, createdAt FROM processed_comments WHERE status='running';"`
2. If any rows come back, they are leftovers from a crashed turn. Reset each:
   `sqlite3 /home/marzec/.openclaw/manul/manul.db "UPDATE processed_comments SET status='queued', processedAt=NULL WHERE commentId='<commentId>';"`
3. The daemon's next poll (≤60s) will rebuild the queue with full task details and dispatch them. Mention recovered leftovers in your final summary.
   If the queue.json you already read in Step 0 contained tasks, process those normally — do NOT double-process a task you just reset (it is not in the current queue.json yet).

**Important:** if Step 0.5 finds NO `running` rows (the usual case), move straight to Step 1. Do not spend time "investigating" — the queue in Step 0 is what you process.

## Step 1 — Process each task

For every task in queue.json — **process it NOW, in this turn, without investigating anything else**:

**Escalation context:** the task carries `attempts` (how many times a worker
has already run on it and failed). `attempts=0` → first try. Each failed run
increments `attempts`; the daemon re-queues failed tasks automatically as long
as `attempts <= 2`. Your job: pick the right agent tier for the CURRENT
attempt (see step 2) and, on failure, decide whether to escalate or give up.

1. Mark running:
   `sqlite3 /home/marzec/.openclaw/manul/manul.db "UPDATE processed_comments SET status='running' WHERE commentId='<commentId>';"`

2. Resolve the agent (read the known list from config if needed:
   `jq -r '.agents[]' /home/marzec/.openclaw/manul/config.json`):
   - If the task already has an explicit `agent` (from the trigger) AND
     `attempts == 0`, use it.
   - Otherwise pick by escalation tier based on `attempts`:
       attempts 0 → default `coder` (NORMAL tier) — or the explicit agent if set
       attempts 1 → escalate: `coder-strong` (STRONG) if the role is coding
                    (reviewer/debugger/etc. → their -expert variant); keep the
                    same role family, just one tier higher
       attempts 2 → escalate again: `coder-expert` (EXPERT)
   - Escalation map (role → attempts1 → attempts2):
       coder        → coder-strong  → coder-expert
       debugger     → debugger-expert
       reviewer     → reviewer-expert
       (other roles: same family, -expert at attempts≥1; if no expert variant
        exists, keep the role but note the escalation in the Running comment)
   - `agent` empty → default agent is `coder`. BUT first check the prompt's
     first word: if it is a plausible (case-insensitive, close) spelling of a
     known agent name, the user probably meant an explicit agent — post ONE
     comment that both informs and runs:
     `🤖 Running... Unknown agent '<first-word>' — using the default coder. Known agents: <comma-separated>. Accepted the task: <prompt, first 200 chars>`
     and proceed with `coder`.
   - Otherwise (no agent requested) → default `coder`.

3. Post the running comment (English), using the helper:
   - explicit agent: `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "🤖 Running... (agent: <agent>) Accepted the task: <prompt, first 200 chars>"`
   - default: `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "🤖 Running... Accepted the task: <prompt, first 200 chars>"`
   - escalation round: `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "🤖 Running... (attempt <n+1>, escalated to <agent>) Accepted the task: <prompt, first 200 chars>"`

   **feedback.sh signs automatically — NEVER include `— manul 🐈` in the message you pass to it** (it would be added a second time).

   **If the task came from a PR review comment** (commentId starts with `review:`,
   e.g. `review:3740554181`): reply INSIDE the review thread instead of the PR
   conversation — pass `--in-reply-to <numeric-id-after-review:>`:
   `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "🤖 Running... Accepted the task: <prompt, first 200 chars>" --in-reply-to 3740554181`

   If the prompt is vague or does not describe a concrete task (e.g. it just
   says "do it", "fix this"), fetch the issue context first and
   use it as the task description:
   `gh issue view <issueNumber> --repo <repository>` — pass the issue
   title + body to the worker as the actual task. If the task carries
   `context.issue` (JSON from the queue), use THAT instead of fetching.

   **If the task came from a PR review comment** (commentId starts with `review:`,
   e.g. `review:3740554181`): the worker needs the complete context — the
   comment, the code spot, the PR, AND the issues the PR links to:
   - **If the task has a `context` field** (enriched by the poller): pass it to
     the worker VERBATIM — it already contains the full PR body, every issue
     linked in the PR body (title+body, e.g. the task issue), and the comment
     path/line/diffHunk. Do NOT re-fetch anything.
   - **Legacy tasks without `context`**: fetch it yourself:
     - `gh api repos/<repository>/pulls/comments/<review-comment-id>` (gets diff_hunk, path, body, line)
     - `gh pr view <issueNumber> --repo <repository>` (gets PR title, body, state)
     - **ALWAYS also fetch every issue linked in the PR body** (regex `issues/(\d+)` / `#(\d+)` / `owner/repo#\d+`): `gh issue view <n> --repo <owner/repo> --json number,title,body` and include each title+body.
   Pass ALL of this (full comment body, file/diff, PR body, linked issues) as part of the subagent task description.

4. Spawn ONE subagent with `sessions_spawn` (mode=run, runtime=subagent, taskName=`manul-<issueNumber>-<agent>`). Use `agentId=<agent>` (the resolved role agent, e.g. `coder`, `reviewer`, `debugger`) — its system prompt/model come from the OpenClaw agent config. Pass `cwd` = the repo work dir. The subagent brief (write it explicitly):

   ---
   You are a manul worker running as the `<agent>` role agent (your role's
   system prompt and model come from the OpenClaw agent config). Fix a task
   requested via GitHub comment. The manul contract below still governs
   everything GitHub-related:
   - Repository: `<repository>` (use `gh` CLI; auth is already set up)
   - Task (from comment `<commentUrl>` by `<author>`): `<prompt>`
     If the task carries a `context` field, append it verbatim:
     `- Context (enriched by the poller): <context JSON — PR body, linked issues, comment path/line/diff>`
   - Work dir: `/home/marzec/.openclaw/manul/work/<repository-slashed-to-dash>` — `gh repo clone <repository> <dir>` if missing, else `cd` + `git fetch origin` + checkout the default branch (resolve via `gh repo view <repository> --json defaultBranchRef -q .defaultBranchRef.name`).
   - Create branch `<type>/manul/<issueNumber>-<short-kebab-slug>` where `<type>` is `feature` for new functionality/changes/improvements and `bugfix` for bug fixes (judge from the task; when in doubt use `feature`). `<issueNumber>` is the issue/PR number the task came from. Slug from the prompt, max ~40 chars, alnum+dash. Examples: `feature/manul/12-update-ktor`, `bugfix/manul/3-fix-crash-on-empty-input`.
   - **Plans/proposals/analyses go in a COMMENT, never in a PR with a markdown file.** If the task is a plan, proposal, analysis, or „don't code yet“ request: DO NOT create a branch/PR/md file. Instead write the plan as a reply comment on the issue (use `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "<plan>"`) and include a short summary in the ✅ Done comment. The ONLY exception: the task EXPLICITLY asks for a markdown file / document in the repo (e.g. „add docs/plan.md“) — then do the PR as usual.
   - Implement the minimal fix for the task. Run the relevant tests/build (check for README/Makefile/package.json/gradle etc.). If tests fail after a genuine best effort, report that honestly.
   - **CI Build / Check Inspection (skipCiFix=false only):** If this task relates to an existing PR (or after pushing a new branch/PR), check GitHub Actions or CI check status using `gh pr checks` or `gh run list --branch <branch>`. If any CI checks or builds are failing (`failure`), investigate the failure logs using `gh run view <run-id> --log-failed` (or `gh pr checks`), fix the root cause in the code, commit, and push so CI passes.
   - Commit with a conventional message (e.g. `fix: <summary>`). NEVER use `--author`, never change git author config. Append the trailer line `Co-authored-by: AI Agent <agent@ai.local>` to every AI-created commit (ai-commit-attribution skill). Push to origin.
   - Resolve the correct PR base branch: use the branch that the new feature branch was created from, NOT the repository default branch. If the branch was explicitly created from a named base branch, use that branch. If `develop` exists and the branch was based on it, use `develop`. Otherwise use the repository default branch. You can inspect this with `git branch --show-current` before branching, or from branch history.
   - If `/home/marzec/.openclaw/manul/config.json` has `autoCreatePr: true` → create the PR with a MEANINGFUL description (never a stub like "Task from comment"): write the body to `/tmp/manul-pr-body.md` and run `gh pr create --base <parent-branch> --title "manul: <short summary>" --body-file /tmp/manul-pr-body.md`; otherwise just push the branch.
   - **Resolved review threads:** When processing review comments, ignore comments whose root review thread is already resolved. Only act on unresolved threads; resolved threads are not actionable and should not trigger new work.     The description MUST cover:
       * Task: what was requested (one line + comment URL)
       * Changes: concrete summary of what the diff does (not a copy of the commit message)
       * Verification: what you ran (tests/build) and the result
     Language: match the repository's language — detect it from the README/code
     comments; code repos default to English. End with the signature `— manul 🐈`.
     Example:
       ## Task
       Update the project to the latest ktor (3.5.2) — [issue #4](<commentUrl>)

       ## Changes
       - Bumped ktor to 3.5.2 (and kotlin, if required) in buildSrc/Dependency.kt
       - Added gradle.properties with JVM heap settings

       ## Verification
       - `./gradlew build` passes

       — manul 🐈
   - Do NOT post any GitHub comments yourself, do NOT force-push.
   - Skip if an open PR or a branch matching `feature/manul/<issueNumber>-*` or `bugfix/manul/<issueNumber>-*` already exists for this task (report as already-exists).
   - End your final reply with EXACTLY ONE line starting `MANUL_RESULT ` in the form:
     `MANUL_RESULT status=ok branch=<branch> commit=<sha> pr_url=<url-or-> summary=<one line>`
     or `MANUL_RESULT status=failed reason=<short reason>`
   ---

5. When the subagent finishes: parse its `MANUL_RESULT` line.
   - ok → `UPDATE processed_comments SET status='done', processedAt='<now>' WHERE commentId='<commentId>';` then post (in-thread if review comment, same rule as step 3):
     `/mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh <repository> <issueNumber> "✅ Done

Summary: <summary>
Branch: <branch>
Commit: <commit>
PR: <pr_url>"` (omit PR line if none)

     Same rule: the message must NOT contain the signature — feedback.sh appends `— manul 🐈` itself.
   - failed → decide: escalate or give up.
     * Read the task's current attempts: `sqlite3 ... "SELECT attempts FROM processed_comments WHERE commentId='<commentId>';"`
     * If `attempts < 2` (more escalation rounds allowed):
       `UPDATE processed_comments SET status='failed', attempts=attempts+1, processedAt='<now>' WHERE commentId='<commentId>';`
       then post a short comment: `❌ Failed (attempt <n+1>) — retrying with a stronger agent.

Reason: <reason>`
       The daemon's next poll re-queues it and the next turn escalates.
       Do NOT post the full ❌ Failed summary yet — the task is not finished.
     * If `attempts >= 2` (no rounds left): `UPDATE ... SET status='failed', attempts=attempts+1 ...` then post the honest final: `❌ Failed

Reason: <reason>`
       and do NOT re-queue (the daemon's re-queue guard stops at `attempts > 2`).
   - If you spawned subagents, use `sessions_yield` and wait for completion events before finishing.

## Step 2 — Finish

- Reply with a compact summary of what was done (task → status → PR URL).

## Hard rules

- Never include the literal trigger `/manul` in any comment you post (self-trigger protection). Note: the poller ALSO ignores any comment signed with `— manul 🐈` (feedback.sh signs all bot comments), so a path like `docs/manul-…` inside a bot comment no longer re-triggers — but keep the no-trigger rule anyway.
- NEVER create a PR targeting `develop` (or any non-default branch). The PR base is always the repository's default branch (e.g. `main`, `master`) — resolve it via `gh repo view <repository> --json defaultBranchRef -q .defaultBranchRef.name`.
- All GitHub comments (🤖 Running…, ✅ Done) are written in English; PR descriptions are written in English (code repos); code/technical identifiers stay as-is. Manul never writes Polish on GitHub.
- Never force-push. Never touch branches other than `feature/manul/*` and `bugfix/manul/*`.
- Plans/proposals/analyses are always posted as comments on the issue — never as PRs with markdown files — unless the task explicitly requests a markdown file in the repo.
- If anything is ambiguous in a task, do your best with a minimal, safe change and note assumptions in the summary.

```

## Install on a new machine (fresh setup)

1. **Prereqs**: `gh` CLI (logged in: `gh auth login`, scopes `repo`, `workflow`),
   `git`, `sqlite3`, `jq`, OpenClaw installed with the Gateway running
   (`openclaw gateway status`). On Ubuntu/Debian: `sudo apt-get install -y sqlite3 jq`.
2. **Create the directory**:
   ```bash
   mkdir -p /mnt/f/ubuntu-workspace/.openclaw/manul/work
   ```
2b. **Create the isolated `manul` agent** (one brain = one workspace; manul gets
   its own minimal workspace so it never reads the main agent's personal files):
   ```bash
   openclaw agents add manul --workspace /mnt/f/ubuntu-workspace/.openclaw/workspace-manul --non-interactive
   ```
   Then apply the restricted tool/skill policy (operator-side; these config paths
   are agent-protected, so apply with `openclaw config patch` from your shell,
   not from inside an agent session):
   ```json5
   // openclaw config patch --file manul-agent-policy.json5
   {
     agents: {
       list: [
         { id: "main" },
         {
           id: "manul",
           name: "manul",
           workspace: "/home/marzec/.openclaw/workspace-manul",
           agentDir: "/home/marzec/.openclaw/agents/manul/agent",
           // Skills: full shared set (~/.agents/skills → globalskills). The
           // operator deliberately gives manul ALL skills — they encode his
           // coding approach (kotlin-code-formatting, karpathy-guidelines,
           // feature-branching-strategy, ...) and manul should follow them.
           // Keep this list in sync when adding new skills to globalskills.
           skills: ["ai-commit-attribution", "feature-branching-strategy", "github-selfhosted-runner", "globalskills-repository", "karpathy-guidelines", "kotlin-code-formatting", "litellm-db-setup", "manul-github-bot", "wsl-ai-dev-autopilot-multi-device"],
           tools: {
             allow: ["exec", "process", "read", "write", "edit", "apply_patch", "web_search", "web_fetch", "sessions_spawn", "sessions_yield", "subagents", "session_status", "memory_get", "memory_search"],
             deny: ["message", "browser", "canvas", "nodes", "cron", "gateway", "image", "image_generate", "music_generate", "tts", "video_generate", "pdf", "create_goal", "get_goal", "update_goal", "dir_fetch", "dir_list", "file_fetch", "file_write", "skill_workshop", "agents_list", "sessions_list", "sessions_history", "sessions_send", "node_inference"]
           }
         }
       ]
     }
   }
   ```
   Write a minimal `AGENTS.md`/`SOUL.md` into `/mnt/f/ubuntu-workspace/.openclaw/workspace-manul/`
   (bot rules only — no personal data; see the skill repo for a template).
   The daemon dispatches turns with `--agent manul`, so workers and the
   orchestrator always run inside this isolated agent.
3. **Write the files**: copy the exact contents from this skill —
   `config.json`, `poll.sh`, `feedback.sh`, `manul-daemon.sh`,
   `orchestrator.prompt.md` — into `/mnt/f/ubuntu-workspace/.openclaw/manul/`.
4. **Make scripts executable**:
   ```bash
   chmod +x /mnt/f/ubuntu-workspace/.openclaw/manul/poll.sh /mnt/f/ubuntu-workspace/.openclaw/manul/feedback.sh /mnt/f/ubuntu-workspace/.openclaw/manul/manul-daemon.sh
   ```
5. **Edit `config.json`**: set `repositories` to the repos manul should watch and
   `allowedUsers` to the GitHub logins allowed to invoke manul (default: repo owner).
6. **Set the baseline (IMPORTANT — do this BEFORE first daemon start)**:
   ```bash
   sqlite3 /mnt/f/ubuntu-workspace/.openclaw/manul/manul.db "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
   INSERT OR IGNORE INTO meta(key,value) VALUES('baseline','$(date -u +%Y-%m-%dT%H:%M:%SZ)');"
   ```
   (poll.sh also sets it automatically on first run if missing — the explicit
   write just makes the install moment unambiguous.)
7. **Start the daemon**:
   ```bash
   /mnt/f/ubuntu-workspace/.openclaw/manul/manul-daemon.sh start
   ```
8. **Verify**: `/mnt/f/ubuntu-workspace/.openclaw/manul/manul-daemon.sh status`, then check one poll:
   ```bash
   /mnt/f/ubuntu-workspace/.openclaw/manul/manul-daemon.sh run-once
   tail -5 /mnt/f/ubuntu-workspace/.openclaw/manul/daemon.log /mnt/f/ubuntu-workspace/.openclaw/manul/poll.log
   ```

## Baseline semantics (anti-duplication rule)

- **Baseline = install/config moment** (UTC ISO string in `meta.baseline`).
- Manul only reacts to content created **after** the baseline:
  - issue bodies created after baseline,
  - issue comments created after baseline,
  - PR review comments created after baseline.
- Old posts with `/manul` (e.g. an issue from a month ago) are **ignored** after
  a fresh install — no duplicated work.
- **To make manul do an old issue**: comment on it after the baseline with a
  concrete task (e.g. `/manul fix the bug described in this issue`). The
  comment itself is newer than baseline, so it is picked up. If the comment is
  vague ("zrób to"), the orchestrator fetches the issue body as task context.
- **View/reset baseline**:
  ```bash
  sqlite3 /mnt/f/ubuntu-workspace/.openclaw/manul/manul.db "SELECT value FROM meta WHERE key='baseline';"
  sqlite3 /mnt/f/ubuntu-workspace/.openclaw/manul/manul.db "UPDATE meta SET value='$(date -u +%Y-%m-%dT%H:%M:%SZ)' WHERE key='baseline';"
  ```

## Operations

```bash
/mnt/f/ubuntu-workspace/.openclaw/manul/manul-daemon.sh start|stop|status|run-once
```

- Daemon survives Gateway restarts (setsid), **not** WSL reboots — after a WSL
  restart run `start` again.
- Editing `config.json` needs no daemon restart (poll.sh reads it every cycle);
  a new `pollInterval` applies on the daemon's next loop only after a restart
  of the daemon process.
- Logs: `daemon.log` (loop + dispatch + agent rc), `poll.log` (scan details).
- DB statuses: `queued` → `running` → `done` | `failed`.

## Rate limits

GitHub REST = 5000 req/h. Poll requests per cycle ≈ 3 × repos. Keep
`pollInterval` such that `3 × repos × 3600 / pollInterval < 4000`.
Example: 5 repos → 60s interval ≈ 900 req/h (safe). 22 repos → 20s would be
≈ 7900 req/h (too much) → use 60s ≈ 3960 req/h (tight but OK).

## Troubleshooting

- **Nothing happens after a task is queued**: check `daemon.log` for the
  `agent turn finished rc=` line; check the orchestrator session transcript
  under `/mnt/f/ubuntu-workspace/.openclaw/agents/manul/sessions/` (search `manul-worker`).
- **Orchestrator used to self-block**: the daemon's `lock` belongs to the
  daemon. The orchestrator must NOT check/remove it — it was removed from the
  prompt after a bug where fresh lock → `NO_REPLY` → infinite no-op turns.
- **Trigger not detected**: remember the scan covers issue bodies + issue
  comments + PR review comments. A trigger only in a PR *description* is not
  scanned.
- **Worker slow on Gradle/JVM repos in WSL**: builds run through the Windows
  JVM (`/mnt/c/...`) can take 10+ min. `MANUL_AGENT_TIMEOUT` (default 1800s)
  bounds the turn.
- **`openclaw daemon` is NOT a polling daemon**: it only manages the Gateway
  service (systemd/launchd). Do not use it for manul.
- **No systemd in this WSL2**: no systemd timers/user timers — use the setsid
  daemon. PID 1 is `init`.
- **`cron.triggers.enabled` is protected**: agent cannot enable it (unattended
  code execution). If the operator enables it, a native cron variant could
  replace the daemon (see manul README).
- **Self-trigger protection**: feedback.sh strips literal `/manul` from posted
  messages, so manul never reacts to its own comments.

## E2E test procedure

1. Create a throwaway issue in a watched repo with the trigger in the body,
   e.g. `/manul add hello.txt with content hi`.
2. Expect within a few poll cycles: 🤖 Running comment → branch
   `feature/manul/<issue>-<slug>` (or `bugfix/...` for bug fixes) → commit → PR
   (if `autoCreatePr`) → ✅ Done comment → DB status `done`.
3. Helper: `/mnt/f/ubuntu-workspace/.openclaw/manul/e2e-watch.sh` polls until a `manul/*` PR exists
   or DB reaches done/failed, then prints the result.

## Maintenance rule

**Whenever manul config or scripts change, update THIS skill** (the file
contents above are the canonical source) and commit + push to globalskills
master, so a fresh machine always gets the current version:
```bash
cd ~/.globalskills
git add skills/manul-github-bot/SKILL.md README.md
git commit -m "manul: <what changed>"
git push origin master
```

## Roadmap

- [x] MVP: `/manul` trigger, dedupe, worker branch, feedback, optional PR
- [x] Per-agent commands (`/manul <agent-name> <task>`): parser extracts the
      agent from the first token after the trigger (exact match vs `config.json`
      `agents` list), rest = prompt; unknown/misspelled agent → notice comment +
      default `coder`; workers spawn as OpenClaw role agents (`agentId`)
      — no opencode involved
- [x] Escalation: `status=failed` → re-queue with `attempts+1`; orchestrator
      picks one tier higher (coder→coder-strong→coder-expert), max 2 rounds,
      then honest ❌ Failed
- [ ] `/manul orchestrator <task>` → full multi-agent flow
      (architect → coder → reviewer) for large tasks
- [ ] Optional native cron-trigger variant (needs `cron.triggers.enabled`)
