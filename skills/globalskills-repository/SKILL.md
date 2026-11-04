---
name: globalskills-repository
description: Manage the global skills and canonical agent sources in ~/.globalskills. Use when creating or updating skills and runtime-neutral agent definitions, or configuring their generated OpenCode, Copilot, and Manul installations.
---

# Global Skills Repository

## Purpose
Always create new skills in the global skills repository at ~/.globalskills/skills unless the user explicitly requests a different location.

## Rule
- Prefer creating new skills under ~/.globalskills/skills.
- If a skill already exists in another location, move or mirror it into ~/.globalskills/skills when appropriate.
- When a user asks to create or update a skill, use the global skills repository as the default destination.

## Installation and distribution

Keep source files only in the canonical repository:

- Skills: `~/.globalskills/skills/<skill-name>/`
- Agents: `~/.globalskills/agents/<agent-name>.md`

Do not create runtime symlinks to the skills or agents directories. The
Globalskills installer copies complete skills into the native locations for
OpenCode and GitHub Copilot, and compiles each canonical agent file into the
runtime-specific Markdown format:

- Shared skills: `~/.agents/skills/` (discovered by both OpenCode and GitHub Copilot in VS Code, and used by Manul)
- OpenCode agents: `~/.config/opencode/agents/`
- Copilot agents: `~/.copilot/agents/`
- Manul role definitions: `~/.agents/agents/` (Manul adapters strip YAML frontmatter before prepending the shared prompt body)

The generated files are managed output. Make prompt and metadata changes in
`agents/<name>.md`, not in generated runtime files. Manul's OpenClaw, Codex, and
Claude Code adapters read role files from `~/.agents/agents/` and strip their
YAML frontmatter; OpenCode uses its native generated agents and Copilot uses
its own custom-agent format. The OpenCode adapter emits
V2 `permissions` rules and current fields; the Copilot adapter emits Copilot
custom-agent frontmatter. OpenCode V1-only fields such as `permission` and
per-agent `temperature` are not copied into V2 output.

Install or synchronize resources with:

```bash
globalskills install
globalskills update --check
globalskills update
globalskills status
globalskills rollback skill:<name> --runtime all
globalskills rollback agent:<name> --runtime all
```

The installer records source commits and installed-file hashes in
`~/.local/state/globalskills/manifest.json` (or
`$XDG_STATE_HOME/globalskills/manifest.json`). It preserves extra local files,
refuses to overwrite locally modified managed files, and stores previous
versions for rollback. Only the individual `~/.local/bin/globalskills` and
`~/.aicode/aicode` launcher files may be symlinks; do not symlink whole
runtime directories.

## Guidance
- Keep skill names descriptive and scoped to their purpose.
- Store each skill in its own folder with a clear README or skill definition file.
- Use the shared repository as the canonical home for reusable skills.

## Project repository catalog

The canonical project/repository map used by Manul's Todo task routing is
`skills/globalskills-repository/project-repositories.json`.

Each entry contains:
- `name`: canonical GitHub `owner/repo`;
- `aliases`: unambiguous project names/phrases users may put in task descriptions;
- `description`: short project responsibility summary;
- `skills`: relevant skill directory names whose full `SKILL.md` content can
  be injected into an explicitly routed task.

When adding a repository, verify that it exists, add its canonical name and
useful whole-phrase aliases, and link only skills that already exist. Keep
aliases specific: aliases shared by multiple projects are rejected as
ambiguous at runtime unless a longer unique alias is present. Do not add
arbitrary repositories just because a task mentions them; Manul also validates
resolved targets against its configured `repositoryAllowlist`.

The project catalog is not a replacement for Manul's GitHub polling
configuration. `repositories` continues to control GitHub issue polling;
`repositoryAllowlist` controls which catalog repositories Todo tasks may
target.

# README Maintenance
- After creating, removing, or significantly updating a skill, update `README.md` in the repository root (`~/.globalskills/README.md`).
- The README must list every skill with a one-line description matching the skill's `description` field in its frontmatter.
- Keep the table in sync with the actual skill folders.
- **Always update this skill list in README.md after adding or removing any skill** to keep documentation synchronized.

# Skill Benchmarking
- Every new skill must include at least one behavioral benchmark unless the skill is explicitly listed in `skill-benchmarks/config.json` as excluded.
- The benchmark belongs under `skill-benchmarks/cases/<skill-name>/<case-name>/`.
- A benchmark case should contain a small deterministic fixture, a concise agent prompt, and a deterministic verifier that checks the resulting behavior/artifacts.
- When a skill is significantly changed, review and update its benchmark so it still captures the intended behavior and prevents regressions.
- Run benchmarks locally against the current agent backend; the current backend is OpenCode through the adapter in `skill-benchmarks/adapters.py`.
- For useful post-run diagnosis, prefer running with `--mode both`. The resulting `skill-benchmarks/output/<run-id>/report.md` and `report.json` compare both modes and include the tested `SKILL.md` snapshot plus agent/verifier/git artifacts. These output files are local diagnostics and are ignored by git.
- Benchmark execution is intentionally not part of CI. Unit tests for the benchmark framework and adapters should use mocks and must not require a live LLM.
- If a skill is too complex, stateful, destructive, or environment-wide for the generic benchmark runner, add it to the explicit exclusions with a short reason instead of silently skipping it.
- A newly created or materially changed skill is not complete until its benchmark is added/updated or an explicit exclusion is recorded.

## Skills Index (quick reference)
- `chatgpt-supervised-workflow` — Evidence-driven execution workflow for tasks originating from ChatGPT, activated by a ChatGPT `chatId` or explicit supervision context (`~/.globalskills/skills/chatgpt-supervised-workflow/SKILL.md`).
- `freellmapi-environment` — Operational notes for running FreeLLMAPI locally and wiring it into LiteLLM (`~/.globalskills/skills/freellmapi-environment/SKILL.md`).
- `pr-description-management` — Manage GitHub Pull Request descriptions - create PRs with proper descriptions and update PR descriptions when pushing changes. Uses gh CLI for all PR operations. (`~/.globalskills/skills/pr-description-management/SKILL.md`).
- `wsl-ai-dev-autopilot-multi-device` — Automated WSL2 AI dev environment installer and validator (`~/.globalskills/skills/wsl-ai-dev-autopilot-multi-device/SKILL.md`).
