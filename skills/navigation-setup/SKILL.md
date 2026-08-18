# Navigation Setup

## Overview
The navigation system is built around five core concepts:
- **NavigationStore** – a stateful store that retains the navigation stack, handles navigation actions, and caches results.
- **NavigationHost** – a Compose component that renders the current screen based on the store's back‑stack.
- **Router** – a function that maps a `Destination` object to a Composable `ScreenProvider`.
- **NavigationEntry** – a data holder for a destination, its cache key, optional request key and sub‑flow.
- **NavigationAction** – an intent that pushes a destination onto the stack (may contain a `popTo` option).

The navigation flow is a `NavigationState` that owns a list of `NavigationEntry` objects. Each entry can hold a *sub‑flow* which allows nesting of navigation stacks.

## Configuring the NavigationStore in DI
```kotlin
val navigationStoreCacheKey = "NavigationStore"
val cacheKeyProvider = { Random.nextInt(Int.MAX_VALUE).toString() }

fun provideNavigationStore(scope: CoroutineScope): NavigationStore {
    val defaultScreen = if (hasAuth) TodoDestination.Tasks else TodoDestination.Login
    return navigationStore(
        scope = scope,
        stateCache = stateCache,
        cacheKeyProvider = cacheKeyProvider,
        navigationStoreCacheKey = navigationStoreCacheKey,
        defaultDestination = defaultScreen,
        onAfterClosed = {
            // Common clean‑up
            scrollStateCache.remove(it.cacheKey)
        }
    )
}
```
Key arguments:
- `stateReader`, `stateEditor`: provided by the `StateCache`.
- `cacheKeyProvider`: produces a unique key per store instance.
- `navigationStoreCacheKey`: the top‑level key used by the `StateCache`.
- `defaultDestination`: the first screen shown when the app launches.

## Creating a Router
```kotlin
val router = createRouter(
    FeatureToggles::class to @Composable { destination, cacheKey ->
        provideFeatureTogglesScreen(...)
    },
    TodoDestination.AddNewTask::class to @Composable { destination, cacheKey ->
        provideAddNewTaskScreen(destination.taskToEditId, destination.parentTaskId, cacheKey)
    },
    // … other mappings
)
```
`createRouter` takes pairs of destination *classes* and Composable providers. The provider receives the concrete destination instance for extracting parameters.

## Using NavigationHost in Compose
```kotlin
@Composable
fun App() {
    val navStore = rememberCoroutineScope { provideNavigationStore(it) }
    NavigationHost(
        navigationStore = navStore,
        router = ::router
    )
}
```
There are two overloads:
1. `NavigationHost(navigationStore, router)` – displays the top `Destination`.
2. `NavigationHost(navigationStore, routerWithFlowId)` – passes the current flow id to the provider.

## Navigating
```kotlin
navigationStore.next(TodoDestination.AddNewTask)
navigationStore.goBack(result = updatedTask)
navigationStore.closeFlow(result = cancelResult)
```
`next` pushes a new destination. `goBack` pops the current screen, optionally passing a result to the requester. `closeFlow` pops all screens in the current sub‑flow.

## Observing results
```kotlin
// When waiting for a result from a navigation request
val taskObserver: Flow<Task> = navigationStore.observe(REQUEST_ID)

// Observing a structured result (includes options)
val result: Flow<ResultValue<SubResult>> = navigationStore.observeResult(REQUEST_ID)
```
The request ID is an integer provided when calling `next`.

## Example from `DI.kt`
The `DI.kt` file inside the project shows the full router and store configuration:
- Router is built in `DI.routerProvider`.
- Store is created in `DI.provideNavigationStore`.
- The router maps destinations to screen composables such as `FeatureToggleScreen`, `AddNewTaskScreen`, etc.

## Key files
- `NavigationStore.kt` – core navigation logic.
- `NavigationHost.kt` – Compose renderer.
- `Router.kt` – destination‑to‑screen mapping helper.
- `NavigationEntry.kt` – state items.
- `NavigationAction.kt` – commands.
- `DI.kt` – plumbing of router, store and default screen.

## Branching for this change
Branch created: `feature/navigation-setup`.

*All changes are committed and pushed to the remote repository.*
