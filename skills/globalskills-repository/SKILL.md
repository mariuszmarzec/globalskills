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

## Guidance
- Keep skill names descriptive and scoped to their purpose.
- Store each skill in its own folder with a clear README or skill definition file.
- Use the shared repository as the canonical home for reusable skills.
