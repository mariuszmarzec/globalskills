---
name: quickmvi-usage-testing
description: QuickMVI usage and testing guidelines for Kotlin Multiplatform MVI applications. Based on QuickMVI library patterns, testing utilities, and best practices extracted from the QuickMVI project.
license: MIT
---

# QuickMVI Usage and Testing Guide

QuickMVI is a Kotlin Multiplatform library implementing the Model-View-Intent (MVI) architecture pattern. This skill documents usage patterns, testing strategies, and best practices derived from the QuickMVI codebase and its comprehensive test suite.

## Project Structure and Components

QuickMVI provides:
- `Store` implementations for state management
- Intent actions with `onTrigger`, `reducer`, and `sideEffect` blocks
- Compose integration utilities
- Delegate system for modular business logic
- Parent-child store relationships

## Core Usage Patterns

### 1. Basic Store Setup

```kotlin
// Create a simple store with coroutine scope and initial state
class CounterStore(scope: CoroutineScope) : Store<Int>(scope, 0) {
    fun increment() = intent<Int> {
        onTrigger { flowOf(1) }
        reducer { state + resultNonNull() }
        sideEffect { println("Incremented to $state") }
    }
}
```

### 2. Compose Integration

```kotlin
// Collect state in Compose with optional initial actions
@Composable
fun CounterScreen(store: CounterStore) {
    val state: Int by store.collectState {
        store.loadInitialData()
    }
    Button(onClick = { store.increment() }) {
        Text(text = state.toString())
    }
}
```

### 3. Delegate Pattern

```kotlin
// Extract reusable logic into delegates
interface ApiDelegate {
    suspend fun fetchData(): Result<Data>
}

class ApiDelegateImpl : StoreDelegate<Data>(), ApiDelegate {
    override fun fetchData() = intent<Data> {
        onTrigger { flow { emit(apiService.getData()) } }
        reducer { resultNonNull() }
    }
}

// Use delegation in store
class DataStore(scope: CoroutineScope, defaultState: Data) : 
    Store<Data>(scope, defaultState), ApiDelegate by ApiDelegateImpl() {
    // Store methods can call delegate functions
}
```

### 4. Parent-Child Store Relationship

```kotlin
data class ParentState(val count: Int, val user: User)
data class ChildState(val count: Int)

val parentStore = Store(scope, ParentState(0, User()))
val childStore = parentStore.getChildStore(
    scope = childScope,
    initialState = ChildState(0),
    parentToChild = { ChildState(it.count) },
    childToParent = { copy(count = it.count) }
)
```

## Testing QuickMVI Components

QuickMVI provides specialized testing utilities that enforce proper testing patterns.

### 1. Basic Test Setup

```kotlin
// Use runStoreTest for simplified store testing
@Test
fun `test state updates correctly`() = runStoreTest(listOf(0)) {
    store.intent<Int> {
        onTrigger { flowOf(1, 2) }
        reducer { state + resultNonNull() }
    }
    // Verify state progression
    values.isEqualTo(listOf(0), listOf(0, 1), listOf(0, 1, 2))
}
```

### 2. Testing Side Effects

```kotlin
@Test
fun `test side effect execution`() = runStoreTest(0) {
    val mockAction = mockk<suspend (Int) -> Unit>(relaxed = true)
    store.intent {
        onTrigger { flowOf(1) }
        sideEffect(mockAction)
    }
    // Verify side effect was called
    coEvery { mockAction.invoke(any()) }.wasInvoked()
    verify { mockAction.invoke(1) }
}
```

### 3. Testing Intent Actions

```kotlin
@Test
fun `test intent with cancellation`() = runStoreTest(0) {
    store.intent("id") {
        onTrigger {
            flow {
                delay(500)
                emit(1)
                delay(500)
                emit(2)
            }
        }
        cancelTrigger(runSideEffectAfterCancel = true) { result == 2 }
    }
    // Test cancellation behavior
    scope.advanceTimeBy(1000)
    values.isEqualTo(0, 1)
}
```

### 4. Testing Delegate Integration

```kotlin
@Test
fun `test delegate integration`() = scope.runTest {
    val store = TestStore(scope, 0, TestDelegateImpl())
    store.doThings() // Calls delegate's intent logic
    values.isEqualTo(0, 1, 12, 123)
}
```

### 5. Testing Mapped Intents

```kotlin
@Test
fun `test intent mapping`() = runStoreTest(Result.success(1)) {
    val mappedIntent = innerIntent.map<Result<Int>, Int, Int>(
        stateReducer = { newState -> state.map { newState } },
        stateMapper = { it.getOrNull() }
    )
    store.run(mappedIntent)
    values.isEqualTo(Result.success(1), Result.success(2))
}
```

## Testing Best Practices

### 1. Use TestDispatcher Consistently

```kotlin
// Set up test dispatcher for deterministic timing
Store4Impl.stateThread = UnconfinedTestDispatcher(scope.testScheduler)
```

### 2. Test State Evolution

Always verify the complete state progression, not just final state:
- Use `values` collection in tests to capture all state changes
- Verify intermediate states match expected progression
- Test both happy path and error scenarios

### 3. Test Side Effects Separately

- Verify side effects are triggered at correct times
- Use MockK for mocking external dependencies
- Test that side effects don't modify state incorrectly

### 4. Test Cancellation Logic

- QuickMVI supports action cancellation with `cancelTrigger`
- Test that cancelling pending actions works correctly
- Verify that cancelled actions don't produce side effects

### 5. Integration Testing

```kotlin
// Test real component interactions
@Test
fun `test complete flow`() = runStoreTest(0) {
    val store = CounterStore(scope)
    store.loadData()
    store.increment()
    store.reset()
    // Verify complete scenario
}
```

## Verification Commands

### Lint and Format Checks

```bash
# Run detekt for code quality
./gradlew detekt

# Run tests
./gradlew test

# Run all verification
./gradlew check
```

### Test Coverage Requirements

- Unit tests: Minimum 80% line coverage
- Integration tests: Cover all major flows
- Property-based tests: For state transformations
- Concurrency tests: For thread safety

## Common Testing Patterns

1. **State Evolution Testing**: Verify every state transition
2. **Side Effect Testing**: Mock and verify external calls
3. **Cancellation Testing**: Test interrupted flows
4. **Delegation Testing**: Verify delegate method calls
5. **Mapping Testing**: Test intent transformations
6. **Error Handling**: Test failure scenarios

## Debugging Tips

- Use `store.state.test()` to collect state streams
- Add `println` debugs in reducers for tracing
- Use `coEvery` with `answerWith` for complex mock behaviors
- Check `Store4Impl.stateThread` for threading issues

This skill provides comprehensive guidance for implementing and testing QuickMVI-based applications following the patterns established in the QuickMvi library itself.