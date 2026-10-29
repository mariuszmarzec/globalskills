---
name: karpathy-guidelines
description: Behavioral guidelines to reduce common LLM coding mistakes. Use when writing, reviewing, or refactoring code to avoid overcomplication, make surgical changes, surface assumptions, and define verifiable success criteria.
license: MIT
---

# Karpathy Guidelines

Behavioral guidelines to reduce common LLM coding mistakes, derived from [Andrej Karpathy's observations](https://x.com/karpathy/status/2015883857489522876) on LLM coding pitfalls.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.
- Do not add `try/catch` around every call "just in case". Error handling must serve a concrete caller-level requirement, such as converting a failure into UI state, adding recovery, or attaching meaningful context. Otherwise, let the exception propagate naturally.

## 3. Kotlin Coroutines: Suspend Calls and Cancellation

- **By default, do not wrap calls to `suspend` functions in `try/catch`.** A `suspend` call should normally be allowed to propagate exceptions to its caller. Add a `try/catch` only when this layer has a clear responsibility to handle or transform that failure.
- **When a `try/catch` around suspending work is justified, preserve cancellation.** Never swallow `CancellationException` or turn it into an ordinary error/result. Prefer catching `CancellationException` explicitly and rethrowing it before handling other exceptions.
- When code is already inside a coroutine and the intended policy is to handle ordinary exceptions while still cancelling when cancellation races with another failure, call `currentCoroutineContext().ensureActive()` (or `currentCoroutineScope().ensureActive()` where that is the available/project-standard API) in the ordinary-exception path before converting the failure. This prevents reporting a cancellation as a normal error if cancellation happened while the operation was failing.
- Keep catches narrow: catch expected exception types where possible. Avoid `catch (Exception)` or `catch (Throwable)` unless this layer intentionally maps broad failures and cancellation semantics are handled explicitly.
- **Do not add `ensureActive()` or cancellation boilerplate when you don't need a catch in the first place.** If no local error translation or recovery is required, remove the `try/catch` entirely.

Example — let errors propagate when this layer has no error-mapping responsibility:

```kotlin
suspend fun load(): Data = repository.load()
```

Example — convert errors into UI state while preserving coroutine cancellation:

```kotlin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

suspend fun loadForUi(): UiState =
    try {
        UiState.Data(repository.load())
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (exception: Exception) {
        currentCoroutineContext().ensureActive()
        UiState.Error(exception.message ?: "Could not load data")
    }
```

Use the coroutine context API that matches the actual scope and coroutine library version. Verify the available API instead of inventing imports or signatures.

## 4. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 5. Configuration and Integration Contracts

**Configuration names are compatibility contracts, not style choices.**

This applies to keys and names that cross a boundary, including `local.properties`,
Gradle properties, environment variables, CI workflow fixtures, BuildKonfig fields,
JSON/YAML/TOML keys, CLI flags, secrets references, API fields, database columns,
and names exchanged between scripts or modules.

Before changing one:
1. Trace the value from every producer/writer (CI, templates, setup scripts,
   docs, local config examples) to every reader/consumer (build scripts, runtime
   code, validation, tests, deployment).
2. Establish the existing contract from actual consumers, valid configs,
   project documentation, and tests. Do not guess which spelling is "more
   consistent" or "more idiomatic".
3. Preserve exact spelling, case, punctuation, separators, defaults, and
   missing-value behavior. For example, `prodApiUrl` and `prod.apiUrl` are
   different property names. Never rename or normalize such keys as incidental
   cleanup, refactoring, or a convenient way to make one file match another.
4. When a producer and consumer disagree, fix the side that violates the
   established contract; do not churn a stable contract just to accommodate a
   broken fixture or script.
5. A deliberate contract change must be required by the task or justified by
   verified evidence. Update all producers, consumers, examples, CI fixtures,
   tests, and migration/backward-compatibility handling together. Add a
   regression test or CI check for the boundary where practical.
6. In the change summary, state whether contract names were preserved. If any
   name changed, list the exact old/new names and show how every producer and
   consumer was updated.

If the authoritative contract cannot be established, do not make a speculative
rename. Report the conflict and ask for a decision when it materially affects
compatibility or behavior.

## 6. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

Ask yourself:
- Is the simplest correct solution implemented?
- Are tests covering the intended behavior?
- Did I verify the result rather than assume success?
