---
name: human-readable-code
description: Language-agnostic guidance for code that is easy for people to read, understand, maintain, and change. Use when writing, reviewing, or refactoring software in any language.
license: MIT
---

# Human-Readable Code

## Goal

Optimize code for the next person who has to understand, debug, review, or change it. Readability is a practical engineering property: a developer should be able to follow the intent and important decisions without reconstructing the author's thought process.

Prefer clear, direct code over cleverness, architectural ceremony, or reducing line count. Preserve behavior and public contracts that the task does not ask you to change.

---

### Extraction boundaries

When a task requests function extraction, identify the distinct responsibilities it expects to become easier to understand or test. Create one cohesive helper for each requested responsibility when it has meaningful behavior or a clear contract.

Do not create extra helpers for incidental intermediate values, trivial transformations, or sub-steps that belong to the same responsibility. Keep straightforward assembly in the caller. Do not combine separate requested responsibilities in one helper merely because they occur next to each other.

The public entry point should orchestrate the operation-level helpers in a clear sequence. It should remain easy to understand without following a chain of trivial wrappers.

If a proposed helper only gives a name to a single obvious expression or temporary value, keep that work inline unless it has independent domain meaning, meaningful complexity, genuine reuse, or a separately testable contract.

---

## Working approach

1. Read the surrounding code before editing. Follow established naming, formatting, module boundaries, and local conventions unless they are actively harmful to the requested change.
2. Identify the behavior being changed and the smallest relevant area of the codebase.
3. Make the intent visible in names, function boundaries, and control flow.
4. Keep the change scoped. Do not use a small task as an excuse to reorganize neighboring code.
5. Verify behavior with relevant existing tests and add focused tests when the change needs them.

**For extraction tasks:** Identify the distinct responsibilities the task explicitly asks to separate. Create one cohesive helper for each requested responsibility when it has meaningful behavior or a clear contract. Do not add helpers for incidental intermediate values, trivial transformations, or sub-steps that belong to the same responsibility. Keep straightforward assembly in the caller and preserve a clear sequence in the public entry point.

## Functions: small, cohesive, meaningful

Prefer functions with one coherent responsibility and a name that communicates the operation.

Extract a function when it does at least one meaningful job:

- gives a multi-step operation a useful domain name;
- isolates a coherent responsibility or a distinct level of abstraction;
- removes distracting detail from a caller so its main flow becomes easier to follow;
- captures logic that has a clear, independently testable contract;
- removes genuinely shared behavior that has the same meaning and is likely to change together.

Prefer one helper per cohesive domain operation. When a task names or clearly requires several distinct responsibilities to be separated, create one helper for each such responsibility. Avoid additional helpers for incidental intermediate values, simple arithmetic, formatting steps, or temporary representations unless they have independent domain meaning, meaningful complexity, genuine reuse, or a separately testable contract. Keep simple follow-on work with the operation it supports.

**Keep distinct responsibilities distinct:** Do not combine separately requested operations into one helper merely because they occur next to each other. At the same time, do not split one cohesive operation into multiple helpers solely to make each function shorter. Choose boundaries by responsibility and meaning, not by statement count.

**Keep orchestration readable:** The public entry point should call the requested operation-level helpers in a clear sequence and perform only straightforward coordination or assembly. A reader should be able to understand the overall flow without following a chain of trivial wrappers.

When extracting helpers for a multi-step calculation, make the entry point a clear orchestration that calls each helper in sequence. The main function should read like an outline: call helper A, call helper B, call helper C, combine results. Avoid leaving loops or detailed calculation logic in the entry point.

Keep code inline when extraction would only create a forwarding wrapper, hide a simple expression, force readers to jump between locations, or introduce a name that adds no information. A helper for a single arithmetic expression or trivial derivation is not justified.

**Do not use an arbitrary line limit as an extraction rule.** A longer function can be easy to read when its steps form one clear sequence. A short function can be hard to understand when it hides important behavior behind vague names or unnecessary indirection. Optimize for cognitive load and cohesion, not a target line count.

A useful high-level function often reads like a short outline: validate input, calculate a result, persist it, return it. Details can live in named helpers when those helpers represent real operations.

## Names and intent

- Prefer specific names that describe domain concepts and observable behavior.
- Name booleans as questions or states (is_valid, has_access, should_retry) and actions as verbs.
- Avoid vague names such as data, value, manager, handler, process, or helper when a domain-specific name is available.
- Avoid abbreviations unless they are established in the codebase or universally understood in the domain.
- Do not encode implementation details in names when the name should describe the responsibility.

A reader should not need to inspect a function merely to discover what a clearly named call is intended to do.

## Control flow

- Prefer straightforward, visible control flow.
- Reduce nesting when guard clauses or early returns make the happy path easier to follow.
- Keep related conditions together and make important branches explicit.
- Avoid clever expressions, deeply nested ternaries, dense chaining, and compressed one-liners when they make behavior harder to scan.
- Do not split a simple linear sequence into many tiny functions merely to make the main function look short.
- Keep error handling close to the operation that can fail, while preserving the project's established error model.

## Abstractions and reuse

An abstraction must earn its place by making a real concept, variation, boundary, or repeated responsibility easier to understand or change.

Before introducing a class, interface, generic helper, wrapper, factory, strategy, builder, or additional layer, ask:

- Does this represent a concept that exists in the problem domain?
- Does it remove meaningful duplication or isolate a real change boundary?
- Does it simplify the callers, or does it merely move complexity elsewhere?
- Is the indirection worth the extra navigation and concepts a maintainer must learn?

Prefer the simplest design that meets current requirements. Do not build speculative extension points for hypothetical future needs. Do not add an interface solely to mock one implementation in a unit test.

Apply DRY to shared meaning, not just similar syntax. Two blocks that look alike but represent different business rules may be clearer when kept separate. Avoid premature generalization, configuration-heavy helpers, and abstractions with only one trivial forwarding implementation.

Reuse existing project primitives when they already express the concept. Do not introduce a new mini-framework for a local problem.

## Comments and formatting

- Use formatting and whitespace to reveal structure, not to decorate it.
- Comments should explain why a non-obvious decision exists, a constraint that is not visible in code, or a surprising trade-off.
- Do not add comments that merely narrate each statement or repeat a clear function name.
- Prefer removing confusing code over adding a comment that explains avoidable complexity.
- Keep related operations close together and separate distinct phases with meaningful structure.

## Review checklist

Before finishing, ask:

- Can a developer understand the main flow by reading the entry point?
- Do names communicate intent without requiring implementation details?
- Does each extracted function represent a meaningful operation or boundary?
- Did I avoid arbitrary line-count rules and unnecessary forwarding wrappers?
- Did I extract helpers for the meaningful domain operations the task requests?
- Did I avoid creating helpers for intermediate arithmetic or derived values that lack independent domain meaning?
- **Did I create EXACTLY ONE helper per explicitly requested domain operation (no more, no less)?**
- **Did I keep simple assembly arithmetic (subtraction, addition, rounding) inline in the orchestrator?**
- Did I follow the task's requested extraction boundaries without adding extra helpers?
- Did I introduce any abstraction that costs more than it simplifies?
- Are similar-looking pieces actually the same rule, or merely coincidental duplication?
- Is the change limited to what the task requires?
- Did I preserve behavior and relevant public contracts?

When a trade-off is subjective, prefer the option that makes current behavior easiest to explain and change, and briefly document a consequential choice.
