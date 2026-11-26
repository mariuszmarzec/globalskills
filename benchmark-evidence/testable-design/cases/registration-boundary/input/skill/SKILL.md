---
name: testable-design
description: Language-agnostic guidance for designing code that is straightforward to test without test-driven overengineering. Use when shaping logic, dependencies, side-effect boundaries, or test seams.
license: MIT
---

# Testable Design

## Goal

Make important behavior easy to verify with focused, reliable tests while keeping production code simple. Testability should emerge from clear responsibilities and explicit boundaries; it should not become a reason to add layers, interfaces, or injection points everywhere.

Use this skill together with human-readable-code when both are available. Follow the project's existing testing conventions and language/framework-specific testing skills for syntax and tooling.

## Separate decisions from effects

Keep decisions and transformations independent from external effects when doing so makes behavior clearer or easier to verify.

Good candidates for isolated logic include:

- validation and normalization;
- calculations and business rules;
- mapping between input, domain, and output representations;
- decisions about eligibility, ordering, retrying, or state transitions.

Prefer pure functions for this logic when practical: the result should depend on explicit inputs rather than hidden state, current time, randomness, global configuration, or an external service.

Keep side effects at visible boundaries: persistence, network calls, filesystem operations, message delivery, process execution, and interaction with clocks or random sources. A caller or a small service can orchestrate the sequence while focused functions express the decisions.

Do not force every operation into a pure function. A small cohesive function that coordinates two obvious steps may be easier to maintain than a chain of artificial helpers.

## Make dependencies explicit when useful

Pass a dependency explicitly when it represents a real external capability or variable source that must be controlled, replaced, or observed.

Examples include a clock, random source, repository, HTTP client, filesystem, or message sender.

Use the lightest mechanism that fits the codebase:

- an ordinary function parameter may be enough;
- a small existing interface or protocol may be appropriate for a genuine boundary;
- a concrete collaborator or lightweight fake may be simpler than introducing an abstraction.

Do not inject constants, local values, or deterministic helpers just to make them configurable. Do not create an interface for every class, a provider for every value, or a factory solely to make a unit test possible. Keep dependency setup proportional to the behavior being protected.

## Design for observable behavior

- Keep public entry points focused on the contract callers use.
- Isolate domain rules from infrastructure when they have independent meaning or need independent verification.
- Make error outcomes explicit and consistent with the project's conventions.
- Avoid hidden global state and implicit environment reads in logic that should be deterministic.
- Control time, randomness, generated identifiers, and environment-dependent values when their variability affects the behavior under test.
- Do not expose implementation-only methods publicly just to make tests reach them. Prefer testing through public behavior unless an isolated rule is itself a meaningful reusable unit.
- When a task explicitly requests focused tests for an extracted pure helper, you MUST test that helper directly through its contract (representative valid, normalization/edge, and invalid-input cases as relevant). Write at least two focused test cases that call the helper by name (e.g., `test_prepare_registration_valid_input`, `test_prepare_registration_invalid_email`). Do not rely solely on testing through the public orchestration path. Keep tests of the public orchestration path too when it covers effects/integration. Do not expose private APIs or add interfaces/mocks solely to satisfy tests.

## Write representative tests

- Test behavior and contract boundaries, not private implementation details or call sequences that are not part of the contract.
- Prefer real lightweight collaborators, fakes, or stubs when they make a test representative and easy to understand.
- Use mocks to verify meaningful interactions at true boundaries; do not mock every collaborator by default.
- Keep test setup smaller than the behavior it is intended to explain.
- Use descriptive test names and arrange/act/assert structure where it improves clarity.
- Prefer whole-value equality for deterministic value objects and collections when equality represents the contract.
- Add assertions that prove meaningful outcomes. Avoid both assertion-per-field noise and vague tests that only check that no exception was thrown.
- Keep tests deterministic and independent. Do not make correctness depend on execution order, external services, wall-clock time, or shared mutable state.

A test should help a maintainer understand what the code promises. If it becomes coupled to private call order or incidental structure, reconsider the seam or assertion.

## Choose the right test level

Use the narrowest test that gives trustworthy evidence:

- pure decision logic: unit test with direct inputs and expected outputs;
- orchestration: test the public operation with lightweight fakes at external boundaries;
- integration contracts: use a real local implementation or focused integration fixture when practical;
- user-visible behavior: use the project's UI or end-to-end testing approach where unit tests cannot prove it.

Do not duplicate a large suite of low-value tests at every layer. A few representative tests that protect the contract are often more useful than exhaustive tests of trivial helpers.

## Review checklist

Before finishing, ask:

- Can important decisions be tested without starting infrastructure or reaching the network?
- Are side effects visible and located at sensible boundaries?
- Are dependencies explicit only where they represent real variation or an external capability?
- Did I avoid adding interfaces, wrappers, factories, or public test hooks solely for mocking?
- Do tests exercise behavior through a meaningful entry point?
- When a task explicitly requests focused tests for an extracted pure helper, did I add direct tests for that helper's contract?
- Are fakes/stubs more representative and simpler than mocks for this case?
- Are time, randomness, IDs, and environment-dependent inputs controlled where necessary?
- Is the implementation still the simplest design that meets the requirements?
