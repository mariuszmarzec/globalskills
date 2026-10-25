# Unit Testing Guidelines (Language Agnostic)

## Overview

Use these principles for unit and integration tests in any language or framework. Framework-specific skills may add syntax and platform details, but should not override these general rules.

## Core Principles

### 1. Test Structure (AAA Pattern)
- **Arrange**: Set up deterministic inputs, expected values, doubles, and preconditions.
- **Act**: Execute the public production entry point that owns the behavior.
- **Assert**: Verify the observable result or interaction that proves the behavior.

### 2. Test Naming
- Use descriptive names: `methodName_scenario_expectedOutcome`.
- Name tests after behavior, not implementation details.

### 3. Test Isolation and Determinism
- Each test must be independent and deterministic.
- Control time, IDs, randomness, and other variable inputs where practical.
- No shared mutable state between tests.
- Use setup/teardown for common initialization.

### 4. Test Doubles
- **Mocks** verify interactions; **stubs** provide canned responses; **fakes** provide working test implementations.
- Prefer stubs/fakes and real lightweight collaborators when they keep the test representative.
- Mock boundaries, not the system under test or incidental implementation details.

### 5. Assertions: Prefer Whole-Value Equality

Prefer the smallest set of assertions that clearly proves the intended behavior.

When the expected result is a value object, DTO, model, entity, collection, map, or other value with reliable value equality, compare the **whole expected value** with the actual value rather than asserting each field separately. Build a complete, explicit expected value in Arrange and use one equality assertion for the returned object.

For example, prefer:

```kotlin
val expectedToken = PersonalAccessToken(
    userId = 1,
    name = "Test Token",
    tokenHash = "hash123",
    tokenPrefix = "abc1",
    createdAt = fixedCreatedAt,
    expiresAt = null,
    lastUsedAt = null,
)
assertEquals(expectedToken, token)
```

over a sequence of assertions for `userId`, `name`, `tokenHash`, `tokenPrefix`, `createdAt`, `expiresAt`, and `lastUsedAt`.

This is a general rule, not Kotlin-specific: use the test framework's equivalent of whole-object/value equality in any language.

Use whole-value equality when all compared fields have deterministic expected values and equality is meaningful (for example, a value object/data class/record, an immutable DTO, or a collection of such values).

Do **not** force whole-object equality when it would make the test misleading or brittle. Use targeted assertions when:
- the type lacks meaningful value equality (for example, it is a regular class without a suitable `equals`/equality implementation);
- fields are intentionally variable or nondeterministic and should not be part of the contract under test (prefer injecting/fixing the source of variability when practical);
- the behavior under test is specifically a property, state transition, exception, side effect, or interaction;
- equality would hide the contract or produce poor diagnostics.

If a non-deterministic field is part of the expected result, prefer controlling the clock/ID/random source or injecting a fixed value so the complete object can still be compared. Otherwise, assert only the relevant stable property and explain why whole-object equality is inappropriate.

For collections, prefer comparing the complete expected collection when order and contents are part of the contract. Use a set or order-insensitive matcher only when order is intentionally irrelevant.

A test may contain multiple assertions when necessary, but do not add one assertion per field by default. Keep assertions minimal without sacrificing meaningful behavior coverage. Do not merge unrelated behaviors into a single giant test just to reduce assertion count.

### 6. Coverage Guidelines
- Focus on business behavior, regression risks, boundaries, and error paths rather than getters/setters or trivial plumbing.
- Coverage metrics are signals, not a substitute for meaningful assertions; follow repository-specific targets where present.

### 7. Test Speed
- Unit tests should run quickly and avoid external I/O/network/database dependencies unless the test is explicitly an integration test.
- Use in-memory replacements for unit tests and realistic local infrastructure for integration tests.

### 8. Maintainability
- Treat test code with the same care as production code.
- Reuse small, clear test-data builders when they improve readability; avoid opaque factories that hide expected values.
- Refactor tests when refactoring production code.
- Remove obsolete tests only when their coverage is preserved elsewhere.

## Anti-Patterns to Avoid
- Asserting every property separately when whole-value equality is available and reliable.
- Repeating assertions that only restate the same outcome.
- Testing implementation details instead of behavior.
- Flaky tests or uncontrolled clocks/randomness.
- Over-mocking.
- Giant tests covering unrelated scenarios.
- Weakening or deleting tests to make them pass.
- Ignoring test failures.

## Verification Checklist
- [ ] The test follows Arrange–Act–Assert.
- [ ] Inputs and expected values are deterministic where practical.
- [ ] The test exercises the relevant production entry point.
- [ ] Whole-object/value equality is used when it is meaningful and reliable.
- [ ] Targeted assertions are justified when whole-value equality is not appropriate.
- [ ] Assertions prove observable behavior, not merely object construction or plumbing.
- [ ] Tests are isolated and avoid unnecessary mocking.
- [ ] Relevant edge cases and error paths are covered.
- [ ] Test commands and results are reported accurately.
