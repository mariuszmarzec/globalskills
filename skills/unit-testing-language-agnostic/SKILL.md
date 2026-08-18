# Unit Testing Guidelines (Language Agnostic)

## Overview
This skill provides universal principles for writing effective unit tests regardless of programming language or framework.

## Core Principles

### 1. Test Structure (AAA Pattern)
- **Arrange**: Set up test data, mocks, and preconditions
- **Act**: Execute the unit under test
- **Assert**: Verify expected outcomes

### 2. Test Naming
- Use descriptive names: `methodName_scenario_expectedOutcome`
- Example: `calculateTotal_withDiscount_returnsReducedPrice`

### 3. Test Isolation
- Each test must be independent
- No shared mutable state between tests
- Use setup/teardown for common initialization

### 4. Test Doubles
- **Mocks**: Verify interactions (behavior verification)
- **Stubs**: Provide canned responses (state verification)
- **Fakes**: Working implementations for testing
- Prefer stubs/fakes over mocks when possible

### 5. Assertions
- One logical assertion per test (multiple physical assertions OK)
- Use expressive assertion libraries
- Include meaningful failure messages

### 6. Coverage Guidelines
- Target: 80%+ line coverage, 70%+ branch coverage
- Focus on business logic, not getters/setters
- Test edge cases and error paths

### 7. Test Speed
- Unit tests must run in milliseconds
- No I/O, network, or database calls
- Use in-memory replacements

### 8. Maintainability
- Treat test code with same quality as production code
- Refactor tests when refactoring production code
- Delete obsolete tests

## Anti-Patterns to Avoid
- Testing implementation details
- Flaky tests (non-deterministic)
- Over-mocking
- Giant tests covering multiple scenarios
- Ignoring test failures

## Verification Checklist
- [ ] Tests follow AAA pattern
- [ ] Names are descriptive
- [ ] Tests are isolated
- [ ] Appropriate test doubles used
- [ ] Assertions are clear
- [ ] Coverage targets met
- [ ] Tests run fast (<100ms each)
- [ ] No flaky tests