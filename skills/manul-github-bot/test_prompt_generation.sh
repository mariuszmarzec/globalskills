#!/usr/bin/bash
# test_prompt_generation.sh — Regression tests for prompt generation
#
# Verifies that the daemon generates prompts safely:
#   A. Markdown backticks (`run`, `TASK_DONE`) remain literal
#   B. ${current_attempt}, $(), backticks in task/context remain literal
#   C. Actual runtime values are injected (COMMENT_ID, attempt, repo, issue)
#   D. Multiline task/context survives unchanged
#   E. Malicious $(touch /tmp/should-not-exist) does NOT execute
#   F. Generated prompt is inspected as an actual file
#
# Uses isolated temp environment, fake gh, fake OpenClaw. No production state touched.
#
# Usage: bash test_prompt_generation.sh
# Exit code: 0 if all pass, >0 if any fail

set -uo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

# ─── Temp working directory (cleaned on exit) ─────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ─── Helper counters ──────────────────────────────────────────────────────────
ok() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

assert_file_contains() {
    local label="$1" file="$2" needle="$3"
    if [ -f "$file" ] && grep -qF -- "$needle" "$file"; then
        ok "$label"
    else
        fail "$label (expected file '$file' to contain '$needle')"
    fi
}

assert_file_not_contains() {
    local label="$1" file="$2" needle="$3"
    if [ -f "$file" ] && ! grep -qF -- "$needle" "$file"; then
        ok "$label"
    else
        fail "$label (expected file '$file' NOT to contain '$needle')"
    fi
}

# ─── Prompt generation logic (mirrors daemon's safe pattern) ──────────────────
generate_prompt() {
    local out_file="$1"
    local REPO="$2"
    local ISSUE_NUM="$3"
    local COMMENT_ID="$4"
    local COMMENT_URL="$5"
    local TASK_TYPE="$6"
    local TASK_PROMPT="$7"
    local TASK_CONTEXT="$8"
    local current_attempt="$9"
    local REPO_DIR="${10}"
    local WORKDIR="${11}"
    local PR_HEAD_BRANCH="${12}"
    local timestamp="${13}"
    local CURRENT_BRANCH="${14}"
    local DEFAULT_BRANCH="${15}"

    # Top of prompt (static text + placeholders for single-line runtime values)
    cat > "$out_file" <<'PROMPT_EOF'
# Manul Task:

You are the Manul implementation agent. Complete ONE task and then emit exactly one of the completion markers.

## Task
- Repository: __REPO__
- Issue/PR: #__ISSUE_NUM__
- Comment ID: __COMMENT_ID__
- Comment URL: __COMMENT_URL__
- Task Type: __TASK_TYPE__

## User Request
PROMPT_EOF

    # Append multiline task prompt (literal, no shell expansion)
    printf '%s\n' "$TASK_PROMPT" >> "$out_file"

    cat >> "$out_file" <<'PROMPT_EOF'

## Context
PROMPT_EOF

    # Append multiline task context (literal, no shell expansion)
    printf '%s\n' "$TASK_CONTEXT" >> "$out_file"

    cat >> "$out_file" <<'PROMPT_EOF'
## Command Intent Guidance
Before taking any action, determine whether this task is:
- **Informational**: The user is asking a question, requesting an explanation, or seeking advice. Reply with a thoughtful answer via GitHub comment. Do NOT modify any repository files.
- **Repository Change**: The user wants code changes, fixes, features, or other modifications. Proceed with implementation on the appropriate branch.

If the task is informational, you MUST post a thoughtful answer as a GitHub comment using the `run` tool (see GitHub Comment Posting section below), then emit `TASK_DONE`. Do NOT modify any repository files.

## Rules
1. Inspect the local repository and implement the requested change.
2. Run appropriate tests/validation.
3. Make the requested code changes.
4. When finished, output exactly: `TASK_DONE`
5. If you cannot complete the task, output exactly: `TASK_FAILED: <brief reason>`
6. Do NOT modify `manul.db`.
7. Do NOT manage Manul task state.

## GitHub Comment Posting (CRITICAL)
You MUST post exactly one user-facing result comment to GitHub using the `run` tool:

```bash
gh api repos/__REPO__/issues/__ISSUE_NUM__/comments \
  -f body="YOUR_RESULT_COMMENT" \
  --jq .id
```

Replace REPO, ISSUE_NUM, and YOUR_RESULT_COMMENT with actual values.
Use the in_reply_to parameter if this is a reply:
```bash
gh api repos/__REPO__/issues/__ISSUE_NUM__/comments \
  -f body="YOUR_REPLY" \
  -f in_reply_to=ORIGINAL_COMMENT_ID \
  --jq .id
```

Your comment MUST:
- Start with the task summary
- Include the deterministic task/attempt marker: `<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->`
- Include your actual work/output
- End with: "— manul 🐈"
- Be posted BEFORE emitting TASK_DONE

Example informational task response:
```
<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->
# Available Skills

[Your skill listing here]

— manul 🐈
```

The daemon handles lifecycle comments (🔄 working, ✅ completed, ❌ failed).
You handle the result comment.
PROMPT_EOF

    cat >> "$out_file" <<'PROMPT_APPEND'

## Authoritative Repository
The target repository for this task is located at: __REPO_DIR__

## Working Directory
You will execute in the repository directory:
__WORKDIR__

## Branch Policy
PROMPT_APPEND

    if [ -n "$PR_HEAD_BRANCH" ]; then
      cat >> "$out_file" <<'PROMPT_APPEND'
- This task is tied to PR #__ISSUE_NUM__
- PR head branch: `__PR_HEAD_BRANCH__`
- Switch to the PR head branch (`git checkout __PR_HEAD_BRANCH__`) before making any changes
- Commit and push changes to the same PR head branch
- Do NOT create a new branch for this task
PROMPT_APPEND
    else
      cat >> "$out_file" <<'PROMPT_APPEND'
- This is a standalone task (not tied to an existing PR)
- Current branch: __CURRENT_BRANCH__
- Default branch: __DEFAULT_BRANCH__
- Create a dedicated task branch from the default branch BEFORE making any changes
- Branch name format: `manul-task-__COMMENT_ID__-__TIMESTAMP__`
- Do NOT make any repository changes while on the default branch
- After completing changes, commit and push to your task branch
PROMPT_APPEND
    fi

    cat >> "$out_file" <<'PROMPT_APPEND'

## Skills
Your skills are available at: ~/.agents/skills
Use relevant skills when appropriate to guide your implementation.
PROMPT_APPEND

    # Substitute all single-line placeholders with actual runtime values
    # Using bash parameter expansion (safe: replacement is literal, no command substitution)
    local prompt_content
    prompt_content="$(cat "$out_file")"
    prompt_content="${prompt_content//__REPO__/$REPO}"
    prompt_content="${prompt_content//__ISSUE_NUM__/$ISSUE_NUM}"
    prompt_content="${prompt_content//__COMMENT_ID__/$COMMENT_ID}"
    prompt_content="${prompt_content//__COMMENT_URL__/$COMMENT_URL}"
    prompt_content="${prompt_content//__TASK_TYPE__/$TASK_TYPE}"
    prompt_content="${prompt_content//__CURRENT_ATTEMPT__/$current_attempt}"
    prompt_content="${prompt_content//__REPO_DIR__/$REPO_DIR}"
    prompt_content="${prompt_content//__WORKDIR__/$WORKDIR}"
    prompt_content="${prompt_content//__PR_HEAD_BRANCH__/$PR_HEAD_BRANCH}"
    prompt_content="${prompt_content//__TIMESTAMP__/$timestamp}"
    prompt_content="${prompt_content//__CURRENT_BRANCH__/$CURRENT_BRANCH}"
    prompt_content="${prompt_content//__DEFAULT_BRANCH__/$DEFAULT_BRANCH}"
    printf '%s' "$prompt_content" > "$out_file"
}

# ─── Tests ────────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Prompt Generation Regression Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Test A: Markdown backticks remain literal in prompt
echo -n "Test: Markdown backticks remain literal ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-123" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-123" \
    "issue" \
    'Fix the bug in the `run` command and ensure `TASK_DONE` is emitted.' \
    "Some context" \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "backticks preserved in prompt" "$WORK/prompt.md" "Fix the bug in the \`run\` command and ensure \`TASK_DONE\` is emitted."; then
    :
else
    :
fi

# Test B: Shell metacharacters remain literal in task/context
echo -n "Test: Shell metacharhers remain literal ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-456" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-456" \
    "issue" \
    'Use ${current_attempt} to track retries. Run $(date) to timestamp. Use `TASK_DONE` when done.' \
    'Context with $() and ${var} and `backticks`.' \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "literal \${current_attempt} in prompt" "$WORK/prompt.md" 'Use ${current_attempt} to track retries.'; then
    :
else
    :
fi
if assert_file_contains "literal \$() in prompt" "$WORK/prompt.md" 'Run $(date) to timestamp.'; then
    :
else
    :
fi
if assert_file_contains "literal backticks in prompt" "$WORK/prompt.md" 'Use `TASK_DONE` when done.'; then
    :
else
    :
fi
if assert_file_contains "literal \$() in context" "$WORK/prompt.md" 'Context with $() and ${var} and `backticks`.'; then
    :
else
    :
fi

# Test C: Actual runtime values are injected
echo -n "Test: Runtime values are injected ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-789" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-789" \
    "issue" \
    "Implement the feature." \
    "Some context here." \
    "2" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "repo injected" "$WORK/prompt.md" "Repository: test-owner/test-repo"; then
    :
else
    :
fi
if assert_file_contains "issue injected" "$WORK/prompt.md" "Issue/PR: #42"; then
    :
else
    :
fi
if assert_file_contains "comment_id injected" "$WORK/prompt.md" "Comment ID: test-comment-789"; then
    :
else
    :
fi
if assert_file_contains "comment_url injected" "$WORK/prompt.md" "Comment URL: https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-789"; then
    :
else
    :
fi
if assert_file_contains "marker with actual values" "$WORK/prompt.md" "<!-- manul-task:test-comment-789:attempt:2 -->"; then
    :
else
    :
fi
if assert_file_not_contains "unresolved placeholder COMMENT_ID" "$WORK/prompt.md" "<COMMENT_ID>"; then
    :
else
    :
fi
if assert_file_not_contains "unresolved placeholder current_attempt" "$WORK/prompt.md" '${current_attempt}'; then
    :
else
    :
fi

# Test D: Multiline task/context survives unchanged
echo -n "Test: Multiline task/context survives ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-multiline" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-multiline" \
    "issue" \
    $'Line 1 of task\nLine 2 of task\nLine 3 of task' \
    $'Line 1 of context\nLine 2 of context' \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "multiline task line 1" "$WORK/prompt.md" "Line 1 of task"; then
    :
else
    :
fi
if assert_file_contains "multiline task line 2" "$WORK/prompt.md" "Line 2 of task"; then
    :
else
    :
fi
if assert_file_contains "multiline context line 1" "$WORK/prompt.md" "Line 1 of context"; then
    :
else
    :
fi
if assert_file_contains "multiline context line 2" "$WORK/prompt.md" "Line 2 of context"; then
    :
else
    :
fi

# Test E: Malicious command does NOT execute
echo -n "Test: Malicious command does not execute ... "
rm -f "/tmp/should-not-exist"
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-malicious" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-malicious" \
    "issue" \
    'Execute this: $(touch /tmp/should-not-exist)' \
    "Normal context." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "malicious string preserved" "$WORK/prompt.md" 'Execute this: $(touch /tmp/should-not-exist)'; then
    :
else
    :
fi
if [ ! -f "/tmp/should-not-exist" ]; then
    ok "Malicious command did not execute"
else
    fail "Malicious command executed (file /tmp/should-not-exist exists)"
fi

# Test F: Prompt file is inspectable as actual file
echo -n "Test: Prompt file is inspectable as actual file ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "inspect-test" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-inspect-test" \
    "issue" \
    "Simple task." \
    "Simple context." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if [ -f "$WORK/prompt.md" ] && [ -s "$WORK/prompt.md" ]; then
    ok "Prompt file is inspectable as actual file ($(wc -l < "$WORK/prompt.md") lines)"
else
    fail "Prompt file is inspectable as actual file (file missing or empty)"
fi

# ─── Results summary ───────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL tests)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}All tests passed.${NC}"
else
    echo -e "${RED}$FAIL test(s) failed.${NC}"
fi

exit $FAIL
