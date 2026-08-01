---
name: ai-commit-attribution
description: Preserve the human developer as the Git commit author and add a Co-authored-by trailer to every AI-created commit. Use whenever creating a Git commit. Never change Git author config, never use --author, and always append the OpenCode <opencode@ai.local> trailer (or the identity of the active agent outside OpenCode).
license: MIT
---

# AI Commit Attribution

## Purpose

Whenever creating a Git commit, preserve the human developer as the commit author.
The AI agent must never replace or modify the Git author identity.

Every commit created by an AI agent must clearly indicate that it was AI-assisted by adding a `Co-authored-by` trailer.

## Rules

- Do NOT change `git config user.name`.
- Do NOT change `git config user.email`.
- Never use `git commit --author`.
- Never impersonate the AI as the primary author.
- Always use the currently configured Git identity as the commit author.
- Always append a `Co-authored-by` trailer to commits created by the AI.
- Preserve any existing commit trailers (such as `Signed-off-by`, `Reviewed-by`, etc.) and append the AI trailer after them.

## OpenCode Identity

When running inside OpenCode, always use the following identity:

```
Co-authored-by: OpenCode <opencode@ai.local>
```

This identity must always be used, regardless of which underlying model generated the code (GPT-5, Claude, Gemini, local LLM, etc.).

The commit should indicate that **OpenCode** created the changes, not the underlying model.

## Other Agent Identities

Outside of OpenCode, use an identity appropriate for the active agent.

Examples:

Claude Code

```
Co-authored-by: Claude Code <claude-code@ai.local>
```

OpenAI Codex

```
Co-authored-by: OpenAI Codex <codex@ai.local>
```

Cursor Agent

```
Co-authored-by: Cursor Agent <cursor-agent@ai.local>
```

Gemini CLI

```
Co-authored-by: Gemini CLI <gemini-cli@ai.local>
```

If no specific identity is defined, use:

```
Co-authored-by: AI Agent <agent@ai.local>
```

## Commit Format

```
<subject>

<body if needed>

Co-authored-by: OpenCode <opencode@ai.local>
```

## Example

```
feat(auth): support Google login

Implemented OAuth login flow and added token persistence.

Co-authored-by: OpenCode <opencode@ai.local>
```

## Never

- Never replace the human author.
- Never modify Git author configuration.
- Never use the AI identity as the commit author.
- Never remove existing commit trailers.
- Never omit the `Co-authored-by` trailer when the commit was created by the AI.
