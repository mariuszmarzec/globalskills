---
name: globalskills-repository
description: Manage the global skills repository at ~/.globalskills/skills. Use when creating new skills, moving skills between locations, or organizing the shared skill repository.
---

# Global Skills Repository

## Purpose
Always create new skills in the global skills repository at ~/.globalskills/skills unless the user explicitly requests a different location.

## Rule
- Prefer creating new skills under ~/.globalskills/skills.
- If a skill already exists in another location, move or mirror it into ~/.globalskills/skills when appropriate.
- When a user asks to create or update a skill, use the global skills repository as the default destination.

## Installation (linking to ~/.agents/skills)

Skills are discovered by OpenCode from `~/.agents/skills/`. To set up the symlink:

```bash
mkdir -p ~/.agents && ln -s ~/.globalskills/skills ~/.agents/skills
```

Or use the install script (clones repo + creates symlink):

```bash
wget -qO /tmp/install-globalskills.sh https://raw.githubusercontent.com/mariuszmarzec/globalskills/master/install.sh && bash /tmp/install-globalskills.sh
```

## Guidance
- Keep skill names descriptive and scoped to their purpose.
- Store each skill in its own folder with a clear README or skill definition file.
- Use the shared repository as the canonical home for reusable skills.

## README Maintenance
- After creating, removing, or significantly updating a skill, update `README.md` in the repository root (`~/.globalskills/README.md`).
- The README must list every skill with a one-line description matching the skill's `description` field in its frontmatter.
- Keep the table in sync with the actual skill folders.
