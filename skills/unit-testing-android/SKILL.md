# Unit Testing Guidelines (Android Supplement)

## Overview
Android-specific unit testing practices that supplement the language-agnostic guidelines.

## Android Testing Pyramid
```
        ┌─────────────┐
        │   UI Tests  │  ← Few (10%)
        │ (Instrumented)│
        ├─────────────┤
        │Integration  │  ← Some (20%)
        │  Tests      │
        ├─────────────┤
        │  Unit Tests │  ← Many (70%)
        └─────────────┘
```

## Unit Testing on Android

### 1. Local Unit Tests (JVM)
- Run on local JVM (fast, no device needed)
- Location: `src/test/java`
- Use Robolectric for Android framework dependencies
- Test: ViewModels, Repositories, UseCases, Utilities

### 2. Instrumented Tests (Device)
- Run on Android device/emulator
- Location: `src/androidTest/java`
- Use for: Database, SharedPreferences, Parcelable, UI components

### 3. Test Dependencies (build.gradle.kts)
```kotlin
dependencies {
    // Core testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.11.0")
    testImplementation("org.mockito.kotlin:mockito-kotlin:5.1.0")
    
    // Robolectric for Android framework
    testImplementation("org.robolectric:robolectric:4.11")
    
    // Coroutines testing
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
    
    // Truth assertions
    testImplementation("com.google.truth:truth:1.1.5")
    
    // Instrumented
    androidTestImplementation("androidx.test:core:1.5.0")
    androidTestImplementation("androidx.test:rules:1.5.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
}
```

## Architecture-Specific Testing

### ViewModel Testing
```kotlin
@ExperimentalCoroutinesApi
class MyViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()
    
    @Test
    fun `loadData_success_updatesState`() = runTest {
        // Arrange
        val repository = mockk<Repository>()
        every { repository.getData() } returns Result.Success(testData)
        val viewModel = MyViewModel(repository)
        
        // Act
        viewModel.loadData()
        advanceUntilIdle()
        
        // Assert
        assertThat(viewModel.uiState.value).isEqualTo(UiState.Success(testData))
    }
}
```

### Repository Testing
- Test with real database (Room in-memory) or fake
- Verify DAO interactions
- Test error handling (network, cache)

### UseCase/Interactor Testing
- Pure business logic, easy to test
- Mock repository dependencies
- Test success and error paths

## Android-Specific Patterns

### Coroutines Testing
- Use `runTest` from `kotlinx-coroutines-test`
- Use `MainDispatcherRule` for Main dispatcher
- Test timeouts and cancellation

### LiveData/Flow Testing
- Use `InstantTaskExecutorRule` for LiveData
- Collect Flow in `runTest` block
- Use `turbine` library for Flow testing

### Hilt/Dagger Testing
- Use `@HiltAndroidTest` and `HiltAndroidRule`
- Replace modules with test modules
- Use `@UninstallModules` for specific replacements

## Robolectric Best Practices
- Configure SDK version in `robolectric.properties`
- Use `@Config(sdk = [34])` for API-specific behavior
- Shadow classes for system services
- Avoid Robolectric for pure logic tests

## Test Organization
```
src/test/
├── unit/
│   ├── viewmodel/
│   ├── repository/
│   ├── usecase/
│   └── util/
└── integration/
    └── database/

src/androidTest/
├── ui/
├── database/
└── integration/
```

## CI Integration
```yaml
# .github/workflows/test.yml
- name: Run Unit Tests
  run: ./gradlew test --no-daemon
  
- name: Run Instrumented Tests
  uses: reactivecircus/android-emulator-runner@v2
  with:
    api-level: 34
    force-avd-creation: false
    script: ./gradlew connectedAndroidTest --no-daemon
```

## Verification Checklist
- [ ] Local unit tests run without emulator
- [ ] Instrumented tests use emulator in CI
- [ ] Robolectric configured correctly
- [ ] Coroutines tested with `runTest`
- [ ] Hilt modules replaced in tests
- [ ] Database tests use in-memory Room
- [ ] Coverage reported (jacoco)
- [ ] Tests pass on CI

## Common Pitfalls
- Testing Android framework classes directly (use Robolectric)
- Forgetting `advanceUntilIdle()` in coroutine tests
- Not cleaning up coroutines (use `runTest` scope)
- Sharing test databases between tests
- Testing UI logic in unit tests (move to UI tests)