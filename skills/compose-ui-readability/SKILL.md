---
name: compose-ui-readability
description: Jetpack Compose guidance for readable Android UI structure, proportionate composable extraction, and sensible state ownership. Use when writing, reviewing, or refactoring Compose UI.
license: MIT
---

# Compose UI Readability

## Goal

Make Jetpack Compose screens easy to scan, reason about, and change without fighting the declarative UI model. Compose layouts can naturally be longer and more nested than ordinary imperative functions. Optimize for meaningful UI structure and clear state flow, not short source files.

Use this skill only for Jetpack Compose UI. Apply language-agnostic human-readable-code and testable-design principles as well when those skills are available.

## Organize by UI meaning

- Let the screen-level composable communicate the overall page structure and main state flow.
- Extract a section into a named composable when it represents a meaningful visual or domain unit, has substantial independent layout, owns a coherent interaction, or makes the parent materially easier to understand.
- Prefer names based on the UI's role, such as TrainingSummary, ExerciseList, or ProfileHeader.
- Keep tiny, obvious layout details inline when extracting them would only add a file/function hop or a one-line wrapper around a standard composable.
- Do not create a composable for every Text, Row, Column, icon, or modifier chain. Reuse and extraction should improve meaning, consistency, customization, or independent testing.
- Do not split one cohesive visual section into many components just to reduce line count.

A large composable is not automatically a problem. Extract based on semantic structure, cognitive load, and responsibility—not an arbitrary number of lines.

## Keep screen boundaries clear

A screen-level composable is a useful place to connect application state to UI and translate user events into application actions.

- Collect screen state at a clear boundary and pass the values needed by child composables.
- Pass immutable display data and focused event lambdas to UI sections.
- Avoid passing a whole ViewModel into leaf composables when a value or callback expresses exactly what the child needs.
- Keep navigation, persistence, and business operations out of presentational leaf composables.
- Do not duplicate state between a screen and its children.

## Place state at the right level

Keep state as close as practical to the composable that owns and uses it.

- Hoist state to the lowest common ancestor that needs to read or change it.
- Hoist state further when multiple components need a shared source of truth or when business logic genuinely owns the state.
- Keep short-lived, UI-only state local when no other component needs to own or coordinate it. Examples include a local expanded item, temporary menu visibility, or a small presentation-only selection.
- Do not automatically move every remember state into a ViewModel.
- Do not hoist state merely to make a composable stateless when the extra parameters and ownership make the code harder to follow.
- Expose state downward and events upward when that makes ownership and data flow clearer.

## Composable API and Modifier

- Give reusable UI composables focused parameters: pass the information they display or the actions they perform, not a large domain object or entire state holder without a reason.
- Use meaningful event names such as onExerciseSelected or onRetry rather than vague callbacks such as onClick when the event has domain meaning.
- For composables that should participate in caller-controlled layout, expose modifier: Modifier = Modifier and apply it to the root UI element they emit.
- Keep modifier chains readable and preserve their order. Modifier order changes layout, drawing, and interaction behavior; do not reorder chains as cosmetic cleanup.
- Avoid composables with a large set of unrelated Boolean flags. Prefer a small model or a more focused component when it clarifies the API.
- Use stable item keys for lazy collections when items have stable identity and the project model provides it.

## Lambdas and layout structure

- Keep short event lambdas inline when their behavior is obvious.
- Extract a handler when it has multiple steps, is reused, or its name clarifies a domain action.
- Avoid deeply nested conditional UI expressions; use clear branches or named sections when they improve scanning.
- Keep related UI and its state/event wiring close together.
- Do not introduce generic design-system wrappers for a one-off screen element unless the project already has that convention or real reuse is expected.

## Refactoring safety

When reorganizing an existing screen:

1. Preserve displayed content, accessibility semantics, modifier order, and user interactions.
2. Preserve state ownership unless there is a concrete reason to change it.
3. Keep state collection and application actions at the existing screen/application boundary.
4. Extract sections incrementally and pass only the data and callbacks each section needs.
5. Run relevant compile, UI, or screenshot tests available in the project. If UI rendering cannot be validated, state that limitation rather than claiming visual equivalence.

## Review checklist

- Does the parent screen read like a clear outline of the UI?
- Do extracted composables represent meaningful sections rather than trivial wrappers?
- Is each child given only the data and callbacks it needs?
- Is UI-only state kept local, and shared state hoisted only as far as necessary?
- Are state collection and business actions kept at the correct boundary?
- Do modifier parameters and modifier ordering preserve caller control and behavior?
- Are interactions, semantics, labels, and accessibility behavior preserved?
- Did the refactor reduce cognitive load without multiplying components or files unnecessarily?

## Official references

- [Compose UI Architecture](https://developer.android.com/develop/ui/compose/architecture)
- [Where to hoist state](https://developer.android.com/develop/ui/compose/state-hoisting)
- [Compose modifiers](https://developer.android.com/develop/ui/compose/modifiers)
