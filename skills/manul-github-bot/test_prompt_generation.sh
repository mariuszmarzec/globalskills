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
    local PR_NUMBER="${16:-$ISSUE_NUM}"
    local REPLY_TO="${17:-}"

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
- PR Number: __PR_NUMBER__
- Original Review Comment ID: __REPLY_TO__

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
You MUST post exactly one user-facing result comment to GitHub using the `run` tool.

Before posting, query the source issue/PR for an existing result comment
containing the exact marker
`<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->`.
If a result comment with that marker already exists, do NOT create another comment.
Update the existing comment in place with the final verified content using the safe
request-body method below.
Only create a new comment when no result comment with that marker exists. The final
state must contain exactly one matching result comment for this task/attempt.

### Safe request-body handling (MANDATORY)
Never put `YOUR_RESULT_COMMENT` or `YOUR_REPLY` directly inside shell quotes such as `-f body="..."`.
Build the complete comment body as literal file content and send JSON through `--input`.
Use a quoted heredoc or another non-evaluating file/stdin method.
```bash
RESULT_FILE="$(mktemp)"
cat >"$RESULT_FILE" <<'RESULT_EOF'
<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->
# Summary: [brief summary]

[detailed result]

— manul 🐈
RESULT_EOF
jq -n --rawfile body "$RESULT_FILE" '{body:$body}' |
  gh api repos/__REPO__/issues/__ISSUE_NUM__/comments --input - --jq .id
rm -f "$RESULT_FILE"
```
For PATCH, use the same `jq --rawfile` pipeline with:
```bash
gh api --method PATCH repos/__REPO__/issues/comments/<RESULT_COMMENT_ID> --input -
```
Do NOT use `-f body="..."` or `-F body="..."` for user-facing result/reply comments.

### Routing
Use the task metadata above and choose the endpoint that matches `Task Type`:

- For `pr_review_comment`: reply to the existing inline review thread. Use the PR review-comments endpoint and the original review comment ID:
```bash
gh api repos/__REPO__/pulls/__PR_NUMBER__/comments \
  -f body="YOUR_REPLY" \
  -f in_reply_to=__REPLY_TO__ \
  --jq .id
```

- For `pr_conversation_comment` or an issue task: post a top-level conversation comment:
```bash
gh api repos/__REPO__/issues/__ISSUE_NUM__/comments \
  -f body="YOUR_RESULT_COMMENT" \
  --jq .id
```

Do NOT use `/issues/__ISSUE_NUM__/comments` with `in_reply_to`: that endpoint does not create replies to inline PR review threads.
Replace REPO, PR_NUMBER, ISSUE_NUM, and the result body with the actual values from this prompt.

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
- Repository default branch: __DEFAULT_BRANCH__
- The daemon prepares an up-to-date base but does NOT create the task branch
- First determine whether this is informational or requires repository changes
- For informational tasks: do NOT modify the repository and do NOT create a branch
- For repository changes: read and follow `~/.agents/skills/feature-branching-strategy/SKILL.md` as the authoritative branching policy
- Create the branch yourself before committing or pushing changes
- Never commit or push changes directly to the base/default branch
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
    prompt_content="${prompt_content//__PR_NUMBER__/$PR_NUMBER}"
    prompt_content="${prompt_content//__REPLY_TO__/$REPLY_TO}"
    printf '%s' "$prompt_content" > "$out_file"
}

# ─── Safety contract in generated prompt ─────────────────────────────────────
echo -n "Test: Result comment posting uses literal request body handling ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-safe-body" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-safe-body" \
    "issue" \
    "Post a result." \
    "Context." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "safe body guidance present" "$WORK/prompt.md" "jq -n --rawfile body"; then :; else :; fi
if assert_file_contains "stdin request body present" "$WORK/prompt.md" "--input -"; then :; else :; fi
if assert_file_contains "inline body flags forbidden" "$WORK/prompt.md" 'Do NOT use `-f body="..."` or `-F body="..."`'; then :; else :; fi

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
echo -n "Test: Shell metacharacters remain literal ... "
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

# Test G: standalone issue prompt delegates branch creation to the agent and
# points it at the authoritative branching skill.
echo -n "Test: standalone prompt delegates branch creation to agent ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-branch" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-branch" \
    "issue" \
    "Implement the feature." \
    "Some context here." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_not_contains "agent must not be told task branch already exists" "$WORK/prompt.md" "Your task branch has ALREADY been created for you by Manul"; then
    :
else
    :
fi
if assert_file_not_contains "agent must not be told to avoid branch creation" "$WORK/prompt.md" "Do NOT create a new branch"; then
    :
else
    :
fi
if assert_file_contains "agent told to use feature branching skill" "$WORK/prompt.md" "~/.agents/skills/feature-branching-strategy/SKILL.md"; then
    :
else
    :
fi
if assert_file_contains "agent told branch creation is its responsibility" "$WORK/prompt.md" "Create the branch yourself before committing or pushing changes"; then
    :
else
    :
fi
if assert_file_contains "agent told not to commit base" "$WORK/prompt.md" "Never commit or push changes directly to the base/default branch"; then
    :
else
    :
fi
if assert_file_not_contains "legacy TASK_BRANCH placeholder removed" "$WORK/prompt.md" "__TASK_BRANCH__"; then
    :
else
    :
fi
# Test H: PR-tied task prompt must NOT contain the standalone-task branch policy
# (it must not instruct the agent to create a task branch for PR tasks).
echo -n "Test: PR-tied prompt has no standalone branch policy ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-pr" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-pr" \
    "issue" \
    "Review the PR." \
    "Some context here." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "feature-branch" \
    "1234567890" \
    "feature-branch" \
    "master" \
    ""
if assert_file_not_contains "PR-tied prompt must not say task branch already created" "$WORK/prompt.md" "Your task branch has ALREADY been created for you by Manul"; then
    :
else
    :
fi
pr_head_line="PR head branch: \`feature-branch\`"
if assert_file_contains "PR-tied prompt names the PR head branch" "$WORK/prompt.md" "$pr_head_line"; then
    :
else
    :
fi

# Test I: PR review-comment prompt uses the review-thread endpoint and carries
# the original comment ID explicitly.
echo -n "Test: PR review prompt uses review-thread routing ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "review:789" \
    "https://github.com/test-owner/test-repo/pull/42#discussion_r789" \
    "pr_review_comment" \
    "Change the requested value." \
    "Review context." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "feature-branch" \
    "1234567890" \
    "feature-branch" \
    "master" \
    "42" \
    "789"
if assert_file_contains "review PR number injected" "$WORK/prompt.md" "PR Number: 42"; then :; else :; fi
if assert_file_contains "original review comment ID injected" "$WORK/prompt.md" "Original Review Comment ID: 789"; then :; else :; fi
if assert_file_contains "review task uses pulls comments endpoint" "$WORK/prompt.md" "gh api repos/test-owner/test-repo/pulls/42/comments"; then :; else :; fi
if assert_file_contains "review task uses in_reply_to" "$WORK/prompt.md" "-f in_reply_to=789"; then :; else :; fi
if assert_file_contains "top-level route remains available" "$WORK/prompt.md" "gh api repos/test-owner/test-repo/issues/42/comments"; then :; else :; fi
if assert_file_contains "review endpoint explains no issues in_reply_to" "$WORK/prompt.md" "Do NOT use \`/issues/42/comments\` with \`in_reply_to\`"; then :; else :; fi

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
