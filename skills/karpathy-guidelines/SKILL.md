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
- When the code is already inside a coroutine scope and the intended policy is to handle ordinary exceptions while cancelling the coroutine on cancellation, use `currentCoroutineContext().ensureActive()` (or the project's equivalent such as `currentCoroutineScope().ensureActive()`, if that is the API available) in the exception path before converting the failure. This ensures a cancellation that races with an ordinary exception is not incorrectly reported as a normal failure.
- Keep catches narrow: catch the expected exception types where possible. Avoid `catch (Exception)` or `catch (Throwable)` unless the layer intentionally maps any failure and cancellation semantics are handled explicitly.
- Don't use `ensureActive()` as a reason to catch exceptions when no local error handling is needed. If no translation/recovery is required, remove the `try/catch` entirely.

Example — let cancellation and ordinary errors propagate when this layer has no error-mapping responsibility:

```kotlin
suspend fun load(): Data = repository.load()
```

Example — when converting failures into UI state inside a coroutine:

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

Use the coroutine context API that matches the actual scope and coroutine library version. Do not invent imports or APIs: verify the available API if uncertain.

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

## 5. Goal-Driven Execution

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
