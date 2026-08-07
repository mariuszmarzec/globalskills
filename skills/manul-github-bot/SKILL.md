---
name: manul-github-bot
description: Setup, operate, and reinstall the manul GitHub command bot (OpenClaw + gh). Manul reacts to `/manul` in issue/PR comments, implements the task on a `manul/*` branch, pushes, optionally opens a PR, and replies with comments signed "manul 🐈". Use when installing manul on a (new) machine, changing its config, or debugging it.
---

# Manul GitHub Bot 🐈

Manul (kot stepowy, Pallas's cat) is a GitHub command bot driven by OpenClaw.
It watches configured repositories, reacts to the trigger `/manul` in issue
bodies, issue comments, and PR review comments, and implements the requested
task: dedicated branch `manul/<slug>` → commit → push → optional PR → feedback
comments on the issue. Every comment/PR manul writes is signed `— manul 🐈`
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
fire:true? ──► openclaw agent --message-file orchestrator.prompt.md \
                  --session-key manul-worker  (headless, timeout -k 60)
                        │
                        ▼
orchestrator: per task → mark running → post "🤖 Running..." →
              sessions_spawn subagent (worker) → wait (sessions_yield)
                        │
                        ▼
worker: clone repo → branch manul/<slug> → implement → tests → commit
        (Co-authored-by trailer) → push → gh pr create (if autoCreatePr)
                        │
                        ▼
orchestrator: parse MANUL_RESULT → post ✅ Gotowe / ❌ Nie udało się
              → update DB (done/failed)
```

Dispatch is synchronous (daemon waits for the agent turn), so runs never
overlap; `lock` is a backstop with 30 min TTL.

## Files (canonical source lives here — copy from this skill)

| Path | Purpose |
|---|---|
| `~/.openclaw/manul/config.json` | enabled, pollInterval, trigger, autoCreatePr, repositories[] |
| `~/.openclaw/manul/poll.sh` | poller: scan + dedupe + queue rebuild |
| `~/.openclaw/manul/feedback.sh` | post a signed comment (strips literal `/manul`) |
| `~/.openclaw/manul/manul-daemon.sh` | start/stop/status/run-once wrapper around the loop |
| `~/.openclaw/manul/orchestrator.prompt.md` | prompt for the headless orchestrator agent turn |
| `~/.openclaw/manul/manul.db` | SQLite state (created on first poll) |
| `~/.openclaw/manul/queue.json` | pending tasks (rebuilt each poll) |
| `~/.openclaw/manul/poll.log`, `daemon.log` | logs |
| `~/.openclaw/manul/lock` | run lock (TTL 1800s) |
| `~/.openclaw/manul/work/<owner-repo>/` | git clones used by workers |
| `~/.openclaw/manul/e2e-watch.sh` | E2E test helper (polls until PR/done) |

### config.json

```json
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "autoCreatePr": true,
  "repositories": [
    "mariuszmarzec/fiteo",
    "mariuszmarzec/shoppingListGenerator",
    "mariuszmarzec/QuickMVI",
    "mariuszmarzec/todo",
    "mariuszmarzec/fiteoApp"
  ]
}
```

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
  prompt TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',
  createdAt TEXT,
  processedAt TEXT
);" 2>>"$LOG"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);" 2>>"$LOG"

BASELINE="$(sqlite3 "$DB" "SELECT value FROM meta WHERE key='baseline';")"
if [ -z "$BASELINE" ]; then
  BASELINE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT OR IGNORE INTO meta(key,value) VALUES('baseline','$BASELINE');" 2>>"$LOG"
  log "baseline set: $BASELINE"
fi

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
    [ -n "$prompt" ] || continue
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,prompt,status,createdAt) VALUES('$id','$repo',$issue,'$url','$author','$esc','queued','$created');" 2>>"$LOG"
    if [ "$(sqlite3 "$DB" "SELECT changes();")" -gt 0 ]; then
      NEW=$((NEW + 1))
      log "queued $id on $repo#$issue"
    fi
  done < <(gh api --paginate "repos/$repo/issues/comments?per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg base "$BASELINE" '
    .[] | select(.created_at >= $base) | select(.body | contains($trig)) |
    {
      id: ("issue:" + (.id|tostring)),
      repo: $repo,
      author: .user.login,
      created: .created_at,
      url: .html_url,
      issueNumber: (.issue_url | capture("issues/(?<n>[0-9]+)$").n | tonumber),
      body: .body
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
    [ -n "$prompt" ] || continue
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,prompt,status,createdAt) VALUES('$id','$repo',$issue,'$url','$author','$esc','queued','$created');" 2>>"$LOG"
    if [ "$(sqlite3 "$DB" "SELECT changes();")" -gt 0 ]; then
      NEW=$((NEW + 1))
      log "queued $id on $repo#$issue (issue body)"
    fi
  done < <(gh api --paginate "repos/$repo/issues?state=all&since=$BASELINE&per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg base "$BASELINE" '
    .[] | select(.pull_request | not) | select(.created_at >= $base) | select(.body // "" | contains($trig)) |
    {
      id: ("issuebody:" + (.id|tostring)),
      repo: $repo,
      author: .user.login,
      created: .created_at,
      url: .html_url,
      issueNumber: .number,
      body: .body
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
    [ -n "$prompt" ] || continue
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,prompt,status,createdAt) VALUES('$id','$repo',$issue,'$url','$author','$esc','queued','$created');" 2>>"$LOG"
    if [ "$(sqlite3 "$DB" "SELECT changes();")" -gt 0 ]; then
      NEW=$((NEW + 1))
      log "queued $id on $repo#$issue"
    fi
  done < <(gh api --paginate "repos/$repo/pulls/comments?per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg base "$BASELINE" '
    .[] | select(.created_at >= $base) | select(.body | contains($trig)) |
    {
      id: ("review:" + (.id|tostring)),
      repo: $repo,
      author: .user.login,
      created: .created_at,
      url: .html_url,
      issueNumber: (.html_url | capture("pull/(?<n>[0-9]+)").n | tonumber),
      body: .body
    }')
done

# Rebuild queue.json from queued rows
QUEUE_TMP="${QUEUE_JSON}.tmp"
sqlite3 "$DB" "SELECT json_group_array(json_object('commentId',commentId,'repository',repository,'issueNumber',issueNumber,'commentUrl',commentUrl,'author',author,'prompt',prompt)) FROM (SELECT commentId,repository,issueNumber,commentUrl,author,prompt FROM processed_comments WHERE status='queued' ORDER BY createdAt);" 2>>"$LOG" >"$QUEUE_TMP"
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
# feedback.sh <repo> <issueNumber> <message> — post a signed manul comment.
# Strips any literal "/manul" from the message (self-trigger protection) and
# signs with "— manul 🐈". Prints the created comment URL.
set -euo pipefail
repo="$1"
issue="$2"
msg="$3"
msg="${msg//\/manul/manul}"
signed="${msg}"$'\n\n— manul 🐈'
jq -nc --arg body "$signed" '{body: $body}' | gh api "repos/$repo/issues/$issue/comments" --input - -q '.html_url'
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
# `openclaw agent`. Dispatch is synchronous, so runs never overlap; the lock
# file is a backstop.
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
    timeout -k 60 "$AGENT_TIMEOUT" "$OPENCLAW_BIN" agent \
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

## Step 0 — Read the queue

Read `/home/marzec/.openclaw/manul/queue.json` (array of tasks):
`[{"commentId": "...", "repository": "owner/repo", "issueNumber": 12, "commentUrl": "...", "author": "...", "prompt": "..."}]`

- If the file is missing or the array is empty → reply `NO_REPLY` and stop.
- DB: `/home/marzec/.openclaw/manul/manul.db` (sqlite3). Task statuses: `queued` → `running` → `done` | `failed`.
- Lock: the daemon holds `/home/marzec/.openclaw/manul/lock` while you run — it guarantees only one dispatch at a time. Do **not** check or remove it; just proceed with the queue.

## Step 1 — Process each task

For every task in queue.json:

1. Mark running:
   `sqlite3 /home/marzec/.openclaw/manul/manul.db "UPDATE processed_comments SET status='running' WHERE commentId='<commentId>';"`
2. Post the running comment (Polish), using the helper:
   `~/.openclaw/manul/feedback.sh <repository> <issueNumber> "🤖 Running... Przyjąłem zadanie: <prompt, first 200 chars>"`

   If the prompt is vague or does not describe a concrete task (e.g. it just
   says "zrób to", "do it", "fix this"), fetch the issue context first and
   use it as the task description:
   `gh issue view <issueNumber> --repo <repository>` — pass the issue
   title + body to the worker as the actual task.
3. Spawn ONE subagent with `sessions_spawn` (mode=run, taskName=`manul-<issueNumber>`). The subagent brief (write it explicitly):

   ---
   You are a manul worker. Fix a task requested via GitHub comment.
   - Repository: `<repository>` (use `gh` CLI; auth is already set up)
   - Task (from comment `<commentUrl>` by `<author>`): `<prompt>`
   - Work dir: `/home/marzec/.openclaw/manul/work/<repository-slashed-to-dash>` — `gh repo clone <repository> <dir>` if missing, else `cd` + `git fetch origin` + checkout the default branch (resolve via `gh repo view <repository> --json defaultBranchRef -q .defaultBranchRef.name`).
   - Create branch `manul/<short-kebab-slug>` (slug from the prompt, max ~40 chars, alnum+dash).
   - Implement the minimal fix for the task. Run the relevant tests/build (check for README/Makefile/package.json/gradle etc.). If tests fail after a genuine best effort, report that honestly.
   - Commit with a conventional message (e.g. `fix: <summary>`). NEVER use `--author`, never change git author config. Append the trailer line `Co-authored-by: AI Agent <agent@ai.local>` to every AI-created commit (ai-commit-attribution skill). Push to origin.
   - If `/home/marzec/.openclaw/manul/config.json` has `autoCreatePr: true` → create the PR with a MEANINGFUL description (never a stub like "Zadanie z komentarza"): write the body to `/tmp/manul-pr-body.md` and run `gh pr create --base <default> --title "manul: <short summary>" --body-file /tmp/manul-pr-body.md`; otherwise just push the branch.
     The description MUST cover:
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
   - Skip if a branch `manul/<slug>` or open PR for it already exists (report as already-exists).
   - End your final reply with EXACTLY ONE line starting `MANUL_RESULT ` in the form:
     `MANUL_RESULT status=ok branch=<branch> commit=<sha> pr_url=<url-or-> summary=<one line>`
     or `MANUL_RESULT status=failed reason=<short reason>`
   ---

4. When the subagent finishes: parse its `MANUL_RESULT` line.
   - ok → `UPDATE processed_comments SET status='done', processedAt='<now>' WHERE commentId='<commentId>';` then post:
     `~/.openclaw/manul/feedback.sh <repository> <issueNumber> "✅ Gotowe

Podsumowanie: <summary>
Branch: <branch>
Commit: <commit>
PR: <pr_url>"` (omit PR line if none)
   - failed → `UPDATE ... SET status='failed' ...` then post: `❌ Nie udało się

Powód: <reason>`
   - If you spawned subagents, use `sessions_yield` and wait for completion events before finishing.

## Step 2 — Finish

- Reply with a compact summary of what was done (task → status → PR URL).

## Hard rules

- Never include the literal trigger `/manul` in any comment you post (self-trigger protection).
- Bot comments (🤖 Running…, ✅ Gotowe) are written in Polish; PR descriptions are written in the repository's language (English for code repos); code/technical identifiers stay as-is.
- Never force-push. Never touch branches other than `manul/*`.
- If anything is ambiguous in a task, do your best with a minimal, safe change and note assumptions in the summary.
```

## Install on a new machine (fresh setup)

1. **Prereqs**: `gh` CLI (logged in: `gh auth login`, scopes `repo`, `workflow`),
   `git`, `sqlite3`, `jq`, OpenClaw installed with the Gateway running
   (`openclaw gateway status`). On Ubuntu/Debian: `sudo apt-get install -y sqlite3 jq`.
2. **Create the directory**:
   ```bash
   mkdir -p ~/.openclaw/manul/work
   ```
3. **Write the files**: copy the exact contents from this skill —
   `config.json`, `poll.sh`, `feedback.sh`, `manul-daemon.sh`,
   `orchestrator.prompt.md` — into `~/.openclaw/manul/`.
4. **Make scripts executable**:
   ```bash
   chmod +x ~/.openclaw/manul/poll.sh ~/.openclaw/manul/feedback.sh ~/.openclaw/manul/manul-daemon.sh
   ```
5. **Edit `config.json`**: set `repositories` to the repos manul should watch.
6. **Set the baseline (IMPORTANT — do this BEFORE first daemon start)**:
   ```bash
   sqlite3 ~/.openclaw/manul/manul.db "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
   INSERT OR IGNORE INTO meta(key,value) VALUES('baseline','$(date -u +%Y-%m-%dT%H:%M:%SZ)');"
   ```
   (poll.sh also sets it automatically on first run if missing — the explicit
   write just makes the install moment unambiguous.)
7. **Start the daemon**:
   ```bash
   ~/.openclaw/manul/manul-daemon.sh start
   ```
8. **Verify**: `~/.openclaw/manul/manul-daemon.sh status`, then check one poll:
   ```bash
   ~/.openclaw/manul/manul-daemon.sh run-once
   tail -5 ~/.openclaw/manul/daemon.log ~/.openclaw/manul/poll.log
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
  sqlite3 ~/.openclaw/manul/manul.db "SELECT value FROM meta WHERE key='baseline';"
  sqlite3 ~/.openclaw/manul/manul.db "UPDATE meta SET value='$(date -u +%Y-%m-%dT%H:%M:%SZ)' WHERE key='baseline';"
  ```

## Operations

```bash
~/.openclaw/manul/manul-daemon.sh start|stop|status|run-once
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
  under `~/.openclaw/agents/main/sessions/` (search `manul-worker`).
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
   `manul/<slug>` → commit → PR (if `autoCreatePr`) → ✅ Gotowe comment →
   DB status `done`.
3. Helper: `~/.openclaw/manul/e2e-watch.sh` polls until a `manul/*` PR exists
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
- [ ] Per-agent commands (e.g. `/manul <agent-name>`) — parser currently treats
      everything after the trigger line as the prompt
- [ ] Optional native cron-trigger variant (needs `cron.triggers.enabled`)
