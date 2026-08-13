# Android Clean Architecture Skill

This skill consolidates best practices from the CheatDay Android application, which implements a robust clean architecture pattern with advanced caching strategies, MVI state management, and reactive programming using Kotlin coroutines.

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│              UI Layer (View/Fragment)            │
│                 • UI Rendering                   │
│              • Jetpack Fragments/Compose         │
│              • No business logic                 │
└─────────────────────────────────────────────────┘
                           ▲
                           │ observes
┌─────────────────────────────────────────────────┐
│    Presentation Layer (ViewModel + MVI Store)   │
│                                                  │
│    • ViewModel (lifecycle-aware)                │
│    • Store (state management + intents)         │
│    • State models (UI-specific)                 │
│    • Side effects (navigation, dialogs, etc.)   │
└─────────────────────────────────────────────────┘
                           ▲
                           │ calls
┌─────────────────────────────────────────────────┐
│      Domain Layer (Interactors/UseCases)        │
│                                                  │
│    • Business logic orchestration               │
│    • Repository coordination                    │
│    • Domain models (pure, framework-agnostic)   │
│    • No Android dependencies                    │
└─────────────────────────────────────────────────┘
                           ▲
                           │ calls
┌─────────────────────────────────────────────────┐
│       Data Layer (Repositories + DataSources)   │
│                                                  │
│    • Data fetching abstraction                  │
│    • Cache management (memory, local DB)        │
│    • Network communication                      │
│    • Data mapping (entity ↔ domain ↔ DTO)      │
└─────────────────────────────────────────────────┘
```

---

## 1. Data Layer: Repository Pattern with Advanced Caching

### 1.1 Multi-Level Cache Architecture

Implement a tiered caching strategy combining in-memory and persistent storage:

```kotlin
// Memory Cache - Fast, app-lifecycle scoped
class MemoryCache(cacheSize: Int = MAX_CACHE_SIZE) : Cache {
    private val lock = ReentrantLock()
    private val cache: MutableMap<String, MutableStateFlow<Any?>> = 
        LinkedHashMap() // LRU with max size

    override suspend fun put(key: String, value: Any?): Unit = 
        lock.withSuspendLock { /* ... */ }
    
    override suspend fun <T> observe(key: String): Flow<T?> = 
        lock.withSuspendLock { /* returns StateFlow as Flow */ }
}

// Persistent Cache - Survives app restart
class WeightRoomSaver(
    private val weightDao: WeightDao,
    private val userRepository: UserRepository
) : ManyItemsCacheSaver<Long, WeightResult> {
    
    override suspend fun get(): List<WeightResult>? = 
        weightDao.observeWeights(userId).firstOrNull()
    
    override suspend fun observeCached(): Flow<List<WeightResult>?> = 
        weightDao.observeWeights(userId).map { list -> list.map { it.toDomain() } }
}

// Composite Cache - Layered access (memory first, then persistent)
class CompositeManyItemsCacheSaver<ID, MODEL>(
    private val savers: List<ManyItemsCacheSaver<ID, MODEL>>
) : ManyItemsCacheSaver<ID, MODEL> {
    
    override suspend fun get(): List<MODEL>? = 
        savers.firstOrNull()?.get()  // Try memory cache first
    
    override suspend fun observeCached(): Flow<List<MODEL>?> =
        savers.mapIndexed { index, saver ->
            saver.observeCached().filterNotNull().let { flow ->
                if (index > 0) {
                    // Propagate updates from persistent to memory cache
                    flow.onEach { newValue ->
                        savers.firstOrNull()?.updateCache(newValue)
                    }
                } else {
                    flow
                }
            }
        }.merge().distinctUntilChanged()
}
```

**Key Principle:** Use composition to layer caches. Always check memory first, fall back to persistent storage, then network. Propagate updates through all layers.

### 1.2 Cache-First and Network-First Strategies

```kotlin
// GetWithCacheCall: Generic cache-network orchestration
class GetWithCacheCall<T>(
    private val dispatcher: CoroutineDispatcher,
    private val cacheSaver: CacheSaver<T>,
    private val call: suspend () -> Content<T>,
    private val ignoreNetworkResult: Boolean = false
) {
    suspend fun run(): Flow<Content<T>> = withContext(dispatcher) {
        val cached = cacheSaver.get()
        val initial: Content<T> = if (cached != null) {
            Content.Data(cached)          // Immediate UI update from cache
        } else {
            Content.Loading()             // Loading indicator if no cache
        }
        
        merge(
            flow {
                emit(initial)
                val callResult = call()   // Network call happens in background
                if (callResult is Content.Data) {
                    cacheSaver.updateCache(callResult.data)  // Update all cache layers
                }
            },
            cacheSaver.observeCached()
                .filterNotNull()
                .map { Content.Data(it) as Content<T> }  // Emit cache updates
        ).distinctUntilChanged().flowOn(dispatcher)
    }
}

// Usage in repositories
suspend fun observeAll(): Flow<Content<List<MODEL>>> =
    GetWithCacheCall(
        dispatcher = dispatcher,
        cacheSaver = cacheSaver,
        call = { asContent { loadFromNetwork() } }
    ).run()
```

**Pattern Benefits:**
- **Cache-first pattern:** Show cached data immediately, fetch fresh data in background
- **User perceived performance:** UI never blocks on network
- **Automatic refresh:** Cache updates flow to UI via StateFlow/Flow
- **Network failures:** Graceful degradation; cached data still available

### 1.3 Generic CRUD Repository

```kotlin
class CrudRepository<ID, MODEL : Any, CREATE : Any, UPDATE : Any, 
                     MODEL_DTO : Any, CREATE_DTO : Any, UPDATE_DTO : Any>(
    private val dataSource: CommonDataSource<ID, MODEL_DTO, CREATE_DTO, UPDATE_DTO>,
    private val dispatcher: CoroutineDispatcher,
    private val cacheSaver: ManyItemsCacheSaver<ID, MODEL>,
    private val toDomain: MODEL_DTO.() -> MODEL,
    private val updateToDto: UPDATE.() -> UPDATE_DTO,
    private val createToDto: CREATE.() -> CREATE_DTO,
    private val updaterCoroutineScope: CoroutineScope
) {
    enum class RefreshPolicy {
        NO_REFRESH,              // Only update cache, don't refresh full list
        SEPARATE_DISPATCHER,     // Refresh asynchronously in background
        BLOCKING                 // Refresh and block until complete
    }

    suspend fun observeAll(): Flow<Content<List<MODEL>>> =
        GetWithCacheCall(
            dispatcher = dispatcher,
            cacheSaver = cacheSaver,
            call = { asContent { loadAll() } }
        ).run()

    suspend fun observeById(id: ID): Flow<Content<MODEL>> =
        GetWithCacheCall(
            dispatcher = dispatcher,
            cacheSaver = object : CacheSaver<MODEL> {
                override suspend fun get(): MODEL? = 
                    cacheSaver.getById(id)
                override suspend fun observeCached(): Flow<MODEL?> = 
                    cacheSaver.observeCachedById(id)
                override suspend fun updateCache(data: MODEL) {
                    cacheSaver.updateItem(id, data)
                }
            },
            call = { asContent { dataSource.getById(id).toDomain() } }
        ).run()

    suspend fun create(
        create: CREATE,
        policy: RefreshPolicy = RefreshPolicy.SEPARATE_DISPATCHER
    ): Flow<Content<MODEL>> = asContentFlow {
        val createdModel = dataSource.create(create.createToDto()).toDomain()
        cacheSaver.addItem(createdModel)
        createdModel
    }.triggerUpdateIfNeeded(policy).flowOn(dispatcher)

    suspend fun update(
        id: ID,
        model: UPDATE,
        policy: RefreshPolicy = RefreshPolicy.SEPARATE_DISPATCHER
    ): Flow<Content<Unit>> = asContentFlow {
        val updatedModel = dataSource.update(id, model.updateToDto()).toDomain()
        cacheSaver.updateItem(id, updatedModel)
    }.triggerUpdateIfNeeded(policy).flowOn(dispatcher)

    suspend fun remove(
        id: ID,
        policy: RefreshPolicy = RefreshPolicy.SEPARATE_DISPATCHER
    ): Flow<Content<Unit>> = asContentFlow {
        dataSource.remove(id)
        cacheSaver.removeItem(id)
    }.triggerUpdateIfNeeded(policy).flowOn(dispatcher)

    private suspend fun <T> Flow<Content<T>>.triggerUpdateIfNeeded(
        policy: RefreshPolicy
    ): Flow<Content<T>> =
        onEach { content ->
            if (content is Content.Data) {
                when (policy) {
                    RefreshPolicy.NO_REFRESH -> Unit
                    RefreshPolicy.SEPARATE_DISPATCHER -> 
                        updaterCoroutineScope.launch { refreshAll() }
                    RefreshPolicy.BLOCKING -> 
                        refreshAll()
                }
            }
        }

    suspend fun refreshAll() = asContent { loadAll() }.ifDataSuspend {
        cacheSaver.updateCache(data)
    }
}
```

**Design Principles:**
- **Type-safe transformations:** Separate DTOs, domain models, and UI models
- **Flow-based:** All operations return Flow<Content<T>> for reactive UI
- **Pluggable refresh:** Choose when and how to update cached data
- **Testability:** Abstract dataSource allows mocking network/DB layer

### 1.4 DataSource Abstraction

```kotlin
// Common interface for all data sources
interface CommonDataSource<ID, MODEL_DTO, CREATE_DTO, UPDATE_DTO> {
    suspend fun getById(id: ID): MODEL_DTO
    suspend fun getAll(): List<MODEL_DTO>
    suspend fun create(create: CREATE_DTO): MODEL_DTO
    suspend fun update(id: ID, update: UPDATE_DTO): MODEL_DTO
    suspend fun remove(id: Long)
}

// Concrete implementations can be swapped
class WeightDataSourceImpl(private val api: WeightApi) : WeightDataSource {
    override suspend fun getAll(): List<WeightDto> = api.getAll()
    override suspend fun create(create: PutWeightRequest): WeightDto = api.put(create)
    // ...
}

class WeightRoomDataSource(private val dao: WeightDao) : WeightDataSource {
    override suspend fun getAll(): List<WeightDto> = 
        dao.observeWeights().firstOrNull().orEmpty().map { it.toDto() }
    // ...
}
```

**Dependency Injection Strategy:**
```kotlin
@Provides
fun provideWeightDataSource(
    @ApiHost apiHost: String,
    roomDataSource: Provider<WeightRoomDataSource>,
    networkDataSource: Provider<WeightDataSourceImpl>
): WeightDataSource = 
    if (apiHost == Api.LOCALHOST_API) {
        roomDataSource.get()  // Use local database for testing
    } else {
        networkDataSource.get()  // Use network API in production
    }
```

---

## 2. Domain Layer: Interactors and Business Logic

### 2.1 Interactor Pattern

Interactors (also called UseCases) orchestrate business logic across repositories and expose domain models to the presentation layer:

```kotlin
class WeightInteractor @Inject constructor(
    private val userPreferencesRepository: UserPreferencesRepository,
    private val weightResultRepository: WeightResultRepository,
    private val daysInteractor: DaysInteractor  // Compose other interactors
) {

    // Expose simple observable flows for UI
    fun observeTargetWeight(): Flow<Float> = 
        userPreferencesRepository.observeTargetWeight()

    suspend fun observeMinWeight(): Flow<Content<WeightResult?>> =
        weightResultRepository.observeMinWeight()

    // Complex business logic coordination
    suspend fun addWeight(weight: WeightResult): Flow<Content<Unit>> = asContentFlow {
        val lastValue = weightResultRepository.observeLastWeight().dataOrNull()?.value
        val minBeforeNewAdded = weightResultRepository.observeMinWeight().dataOrNull()?.value
        val result = weightResultRepository.putWeight(weight).dataOrNull()

        if (result != null && weight.date.isSameDay(DateTime.now())) {
            lastValue?.let { old ->
                incrementCheatDaysIfNeeded(minBeforeNewAdded, weight, old)
            }
        } else {
            throw IllegalStateException("Adding weight failed")
        }
    }

    // Side effects triggered by business logic
    private suspend fun incrementCheatDaysIfNeeded(
        minBeforeNewAdded: Float?,
        weight: WeightResult,
        old: Float
    ) {
        val target = userPreferencesRepository.observeTargetWeight().first()
        val maxPossible = userPreferencesRepository.observeMaxPossibleWeight().first()
        
        val cheatDaysToAdd = calculateCheatDayAdjustment(
            minBeforeNewAdded, weight.value, old, target, maxPossible
        )
        
        if (cheatDaysToAdd != 0) {
            daysInteractor.incrementCheatDays(cheatDaysToAdd)
        }
    }
}
```

**Best Practices:**
- **Single Responsibility:** Each interactor handles one domain concern
- **Composable:** Interactors can call other interactors
- **Repository Agnostic:** Business logic doesn't know cache implementation details
- **Reactive:** Return Flows to allow UI to subscribe and react to changes
- **Error Handling:** Use Content<T> wrapper for success/error/loading states

### 2.2 Domain Models

Keep domain models pure and independent of any framework:

```kotlin
// Pure Kotlin data class - no Android dependencies
data class WeightResult(
    val id: Long,
    val value: Float,
    val date: DateTime
)

data class Day(
    val id: Long,
    val type: Type,
    val count: Long,
    val max: Long,
    val userId: Long
) {
    enum class Type { CHEAT, WORKOUT, DIET }
}

// Mapping functions to/from DTOs and database entities
fun WeightResultEntity.toDomain() = 
    WeightResult(id, value, DateTime(date))

fun WeightResult.toDb(userId: Long) = 
    WeightResultEntity(id, value, date.millis, userId)

fun WeightResult.toDto(): WeightDto = 
    WeightDto(id.toInt(), value, date.toString(Api.DATE_FORMAT))
```

**Rationale:**
- **Testability:** Domain models require no mocking
- **Reusability:** Can be shared across different UI frameworks (Compose, Views, etc.)
- **Clarity:** Clear separation between layers
- **Independence:** Domain logic doesn't change with UI framework choices

---

## 3. Presentation Layer: MVI with Store and ViewModel

### 3.1 MVI Fundamentals

The MVI (Model-View-Intent) pattern structures the presentation layer around:
- **Model (State):** Single source of truth for UI rendering
- **View:** Observes and renders state
- **Intent:** User actions triggering state changes

Implementation uses the [QuickMVI](https://github.com/mariuszmarzec/QuickMVI) library pattern:

```kotlin
// 1. Define State (immutable, represents what UI should display)
data class WeightsData(
    val weights: List<WeightUiModel> = emptyList(),
    val targetWeight: Float = 0f,
    val minWeight: Float? = null,
    val averageWeekWeight: Float? = null
)

// Wrap in State wrapper for loading/error/data states
typealias WeightsState = State<WeightsData>

// 2. Define Side Effects (one-time events: navigation, toasts, dialogs)
sealed class WeightsSideEffects {
    object ShowTargetWeightDialog : WeightsSideEffects()
    data class OpenWeightAction(val id: String) : WeightsSideEffects()
    object GoToAddResultScreen : WeightsSideEffects()
    data class ShowRemoveDialog(val id: String) : WeightsSideEffects()
    object ShowError : WeightsSideEffects()
}

// 3. Define ViewModel extending StoreViewModel
@HiltViewModel
class WeightsViewModel @Inject constructor(
    private val weightInteractor: WeightInteractor,
    private val loginRepository: LoginRepository,
    defaultState: State<WeightsData>  // Injected from DI
) : StoreViewModel<State<WeightsData>, WeightsSideEffects>(defaultState) {

    // 4. Define Intents (user actions)
    
    fun load() = intent<Content<WeightsData>>("load") {
        // onTrigger: The action (network call, database query)
        onTrigger {
            loadData()  // Returns Flow<Content<WeightsData>>
        }

        // reducer: How state changes in response to the action
        reducer {
            state.reduceDataWithContent(resultNonNull()) { it }
        }
    }

    fun onClick(listId: String) = intent<Unit> {
        // emitSideEffect: One-time event (navigation, dialog, etc.)
        emitSideEffect {
            when (listId) {
                TARGET_ID -> WeightsSideEffects.ShowTargetWeightDialog
                else -> WeightsSideEffects.OpenWeightAction(listId)
            }
        }
    }

    fun onLongClick(listId: String) = intent<Unit> {
        emitSideEffect { WeightsSideEffects.ShowRemoveDialog(listId) }
    }

    fun changeTargetWeight(newTargetWeight: String) = intent<Unit> {
        onTrigger {
            newTargetWeight.toFloatOrNull()?.let { weight ->
                flow {
                    emit(weightInteractor.setTargetWeight(weight))
                }
            }
        }

        emitSideEffect {
            if (result == null) WeightsSideEffects.ShowError else null
        }
    }

    fun removeWeight(id: String) = intent<Content<Unit>> {
        onTrigger { 
            weightInteractor.removeWeight(id.toLong()) 
        }

        reducer {
            state.copy(
                data = state.data?.copy(
                    weights = state.data.weights.filter { it.id != id }
                )
            )
        }
    }

    private suspend fun loadData(): Flow<Content<WeightsData>> =
        combine(
            weightInteractor.observeWeights(),
            weightInteractor.observeTargetWeight().asContentFlow(),
            weightInteractor.observeMinWeight(),
            weightInteractor.observeWeekAverage()
        ) { weights, target, min, average ->
            if (weights is Content.Data && target is Content.Data) {
                Content.Data(
                    WeightsData(
                        weights = weights.data.map { it.toUiModel() },
                        targetWeight = target.data,
                        minWeight = min.dataOrNull(),
                        averageWeekWeight = average.dataOrNull()
                    )
                )
            } else {
                Content.Loading()
            }
        }
}
```

### 3.2 StoreViewModel Base Class

```kotlin
open class StoreViewModel<State : Any, SideEffect>(defaultState: State) : ViewModel() {

    protected val sideEffectsInternal = MutableSharedFlow<SideEffect>()
    val sideEffects: Flow<SideEffect>
        get() = sideEffectsInternal

    private val store = Store4Impl(viewModelScope, defaultState)

    val state
        get() = store.state

    init {
        viewModelScope.launch { store.init() }
    }

    fun <Result : Any> intent(
        id: String? = null, 
        buildFun: IntentBuilder<State, Result>.() -> Unit
    ) {
        store.intent(id, buildFun)
    }

    fun <Result : Any> IntentBuilder<State, Result>.emitSideEffect(
        func: suspend IntentContext<State, Result>.() -> SideEffect?
    ): IntentBuilder<State, Result> {
        this.sideEffect {
            func()?.let {
                sideEffectsInternal.emit(it)
            }
        }
        return this
    }
}
```

**Key Benefits of MVI:**
- **Single State:** UI always renders from one immutable state
- **Testability:** Pure functions (intents → state changes)
- **Predictability:** Clear data flow direction
- **Debugging:** State history shows exact UI at any point
- **Type Safety:** State is strongly typed

### 3.3 UI Consumption

```kotlin
// Fragment/Composable observes state and side effects

fragment {
    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        
        // Observe state changes
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.state.collect { state ->
                    renderWeights(state.data?.weights)
                    renderTargetWeight(state.data?.targetWeight)
                    state.error?.let { showError(it) }
                }
            }
        }

        // Observe one-time side effects
        viewLifecycleOwner.lifecycleScope.launch {
            viewLifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.sideEffects.collect { effect ->
                    when (effect) {
                        is WeightsSideEffects.ShowTargetWeightDialog -> 
                            showTargetWeightDialog()
                        is WeightsSideEffects.OpenWeightAction -> 
                            openWeightDetail(effect.id)
                        is WeightsSideEffects.GoToAddResultScreen -> 
                            navigateToAddWeight()
                    }
                }
            }
        }

        // Fire intents on user actions
        binding.fabAdd.setOnClickListener { viewModel.onFloatingButtonClick() }
        binding.toolbar.setOnMenuItemClickListener { menuItem ->
            when (menuItem.itemId) {
                R.id.action_chart -> { viewModel.goToChart(); true }
                else -> false
            }
        }
    }

    private fun renderWeights(weights: List<WeightUiModel>?) {
        weights?.let { adapter.submitList(it) }
    }
}
```

---

## 4. Data Mapping and Model Layers

### 4.1 Three-Model Architecture

Maintain clear separation between layers:

```
┌──────────────────────┐
│   DTO (from API)     │  Remote data representation
│  WeightDto           │
└──────────────────────┘
           │
           │ toDomain()
           ↓
┌──────────────────────┐
│  Domain Model        │  Pure business logic
│  WeightResult        │  (framework-agnostic)
└──────────────────────┘
           │
           │ toUiModel()
           ↓
┌──────────────────────┐
│  UI Model            │  UI rendering
│  WeightUiModel       │  (may have UI-specific data)
└──────────────────────┘
```

### 4.2 Mapping Strategy

```kotlin
// DTOs - from network API
data class WeightDto(
    val id: Int,
    val value: Float,
    val date: String  // ISO format string
)

// Database Entities - from local database
@Entity(tableName = "weights")
data class WeightResultEntity(
    @PrimaryKey val id: Long,
    val value: Float,
    val date: Long,  // Milliseconds timestamp
    val userId: Long
)

// Domain Models - business logic
data class WeightResult(
    val id: Long,
    val value: Float,
    val date: DateTime
)

// UI Models - rendering
data class WeightUiModel(
    val id: String,
    val displayValue: String,
    val displayDate: String,
    val isHighlighted: Boolean = false
)

// Extension functions for safe, explicit mapping
fun WeightDto.toDomain() = WeightResult(
    id = id.toLong(),
    value = value,
    date = DateTime.parse(date)
)

fun WeightResultEntity.toDomain() = WeightResult(
    id = id,
    value = value,
    date = DateTime(date)
)

fun WeightResult.toDb(userId: Long) = WeightResultEntity(
    id = id,
    value = value,
    date = date.millis,
    userId = userId
)

fun WeightResult.toUiModel(
    targetWeight: Float,
    isMinWeight: Boolean = false
) = WeightUiModel(
    id = id.toString(),
    displayValue = "%.1f kg".format(value),
    displayDate = date.toString("MMM dd, yyyy"),
    isHighlighted = isMinWeight || value >= targetWeight
)
```

**Principles:**
- **No cycles:** DTOs → Domain → UI (never backward)
- **Explicit mappings:** Use extension functions, not implicit conversions
- **Immutable models:** Use data classes with val properties
- **No nullability contamination:** Make null explicit at boundaries

---

## 5. Dependency Injection with Dagger/Hilt

### 5.1 DI Module Organization

```kotlin
@Module
@InstallIn(SingletonComponent::class)
class RepositoryModule {

    @Provides
    @Singleton
    fun provideMemoryCache(cacheSize: Int = 100): Cache =
        MemoryCache(cacheSize)

    @Provides
    @Singleton
    fun provideUserRepository(
        gson: Gson,
        userDao: UserDao,
        preferencesDataStore: DataStore<Preferences>,
        dispatcher: CoroutineDispatcher
    ): UserRepository =
        UserRepository(gson, userDao, preferencesDataStore, dispatcher)

    @Provides
    @Singleton
    fun provideWeightResultRepository(
        @Named(WEIGHTS_REMOTE_REPOSITORY) remoteRepository: WeightCrudRepository,
        @Named(WEIGHTS_ONLY_MEMORY_REPOSITORY) localRepository: WeightCrudRepository,
        @ApiHost apiHost: String
    ): WeightCrudRepository = 
        if (apiHost == Api.LOCALHOST_API) {
            localRepository  // Testing: local-only
        } else {
            remoteRepository  // Production: with network
        }
}

@Module
@InstallIn(SingletonComponent::class)
class CacheModule {

    @Provides
    @Singleton
    @Named(WEIGHTS_MEMORY_CACHE_SAVER)
    fun provideMemoryCacheSaver(
        cache: Cache
    ): ManyItemsCacheSaver<Long, WeightResult> =
        MemoryListCacheSaver(
            key = WEIGHTS_MEMORY_CACHE_KEY,
            memoryCache = cache,
            isSameId = { id == it },
            newItemInsert = sortByInserter(byDescending = true) { it.date }
        )

    @Provides
    @Singleton
    @Named(WEIGHTS_ROOM_CACHE_SAVER)
    fun provideWeightRoomSaver(
        dao: WeightDao,
        userRepository: UserRepository
    ): ManyItemsCacheSaver<Long, WeightResult> =
        WeightRoomSaver(dao, userRepository)

    @Provides
    @Singleton
    @Named(WEIGHTS_CACHE_SAVER)
    fun provideCompositeCacheSaver(
        @Named(WEIGHTS_MEMORY_CACHE_SAVER) memory: ManyItemsCacheSaver<Long, WeightResult>,
        @Named(WEIGHTS_ROOM_CACHE_SAVER) persistent: ManyItemsCacheSaver<Long, WeightResult>
    ): ManyItemsCacheSaver<Long, WeightResult> =
        CompositeManyItemsCacheSaver(listOf(memory, persistent))
}
```

### 5.2 ViewModel Injection

```kotlin
@HiltViewModel
class WeightsViewModel @Inject constructor(
    private val weightInteractor: WeightInteractor,
    private val loginRepository: LoginRepository,
    @Assisted defaultState: State<WeightsData>  // from saved state
) : StoreViewModel<State<WeightsData>, WeightsSideEffects>(defaultState)
```

Use `@HiltViewModel` for automatic ViewModelProvider integration and state restoration.

---

## 6. Testing Strategy

### 6.1 Unit Testing Repositories

```kotlin
@Test
fun observeAll_returnsCachedDataImmediately() = runTest {
    // GIVEN
    val cachedWeights = listOf(WeightResult(1, 70f, DateTime.now()))
    val networkWeights = listOf(WeightResult(2, 71f, DateTime.now()))
    
    val cacheSaver = mockk<ManyItemsCacheSaver<Long, WeightResult>>()
    coEvery { cacheSaver.get() } returns cachedWeights
    coEvery { cacheSaver.observeCached() } returns 
        flow { emit(cachedWeights); emit(networkWeights) }
    
    val dataSource = mockk<WeightDataSource>()
    coEvery { dataSource.getAll() } returns networkWeights.map { it.toDto() }
    
    val repository = CrudRepository(
        dataSource = dataSource,
        dispatcher = Dispatchers.Unconfined,
        cacheSaver = cacheSaver,
        toDomain = { toDomain() },
        updateToDto = { toDto() },
        createToDto = { toCreateDto() },
        updaterCoroutineScope = TestScope()
    )
    
    // WHEN
    val results = repository.observeAll().toList()
    
    // THEN
    assertThat(results)
        .containsExactly(
            Content.Data(cachedWeights),    // Immediate from cache
            Content.Data(networkWeights)    // After network update
        )
        .inOrder()
    
    coVerify { cacheSaver.updateCache(networkWeights) }
}
```

### 6.2 Unit Testing ViewModels

```kotlin
@Test
fun onLoginButtonClicked_successfullySetsCurrentUser() = runTest {
    // GIVEN
    val testState = LoginState()
    val viewModel = LoginViewModel(loginRepository, defaultState = testState)
    val stateCollector = viewModel.state.test(this)
    
    coEvery { loginRepository.login(any(), any()) } returns 
        Content.Data(testUser)
    
    // WHEN
    viewModel.onLoginButtonClicked()
    advanceUntilIdle()
    
    // THEN
    val emittedStates = stateCollector.values
    assertThat(emittedStates)
        .contains(
            testState.copy(data = testUser)
        )
}
```

### 6.3 Testing Best Practices

- **Use runTest and advanceUntilIdle()** for coroutine tests
- **Mock at repository/dataSource boundaries**, not at ViewModel
- **Test state transitions**, not implementation details
- **Use Truth or Kotest** for readable assertions
- **Test error paths** explicitly (network errors, validation, etc.)

---

## 7. Best Practices Checklist

### Architecture Decisions

- [ ] **Single Responsibility:** Each class has one reason to change
- [ ] **Dependency Inversion:** Depend on abstractions, not concretions
- [ ] **Unidirectional Data Flow:** Data flows down, events flow up
- [ ] **No Framework Leakage:** Domain layer has zero Android dependencies
- [ ] **Testability:** All business logic can be tested without Android framework

### Repository Pattern

- [ ] **Cache Layers:** Implement multi-level caching (memory + persistent)
- [ ] **Content Wrapper:** Use State<T> wrapper for Loading/Data/Error states
- [ ] **Explicit Policies:** Choose refresh strategy (BLOCKING, SEPARATE_DISPATCHER, NO_REFRESH)
- [ ] **Async Refresh:** Update full list asynchronously after mutations
- [ ] **Flow-Based:** All read operations return Flow for reactivity

### State Management (MVI)

- [ ] **Single State:** One immutable state per screen
- [ ] **Explicit Intents:** All user actions are methods
- [ ] **Reducers:** Pure functions: (State, Action) → State
- [ ] **Side Effects:** Separate navigation and one-time events
- [ ] **No State Mutations:** Use copy() for data classes

### Testing

- [ ] **Layer-Specific Tests:** Unit test each layer independently
- [ ] **Mock Boundaries:** Mock repositories, not business logic
- [ ] **Flow Testing:** Use test() collector for Flow assertions
- [ ] **Error Paths:** Explicitly test failure scenarios
- [ ] **Deterministic:** No flaky tests; control time with runTest

### Performance

- [ ] **Coroutine Scopes:** Use viewModelScope, lifecycleScope appropriately
- [ ] **Dispatcher Choice:** IO for network/DB, Main for UI, Default for CPU
- [ ] **Memory Cache Size:** Limit with LRU eviction
- [ ] **Lazy Initialization:** Use lazy delegates for expensive objects
- [ ] **Flow Cancellation:** Leverage Job cancellation via scope

---

## 8. Common Patterns and Solutions

### Pattern: Network + Local DB Sync

```kotlin
// Use two data sources: room for local, API for remote
val localDataSource = WeightRoomDataSource(dao)
val remoteDataSource = WeightDataSourceImpl(api)

// Composite cache: memory layer + room persistence
val cacheSaver = CompositeManyItemsCacheSaver(
    listOf(
        MemoryListCacheSaver(key = "weights", memoryCache = cache),
        WeightRoomSaver(dao, userRepository)
    )
)

// CrudRepository with network data source
val repository = CrudRepository(
    dataSource = remoteDataSource,  // Primary source is network
    cacheSaver = cacheSaver
)
```

### Pattern: Cross-Entity Operations

```kotlin
// Interactor coordinates multiple repositories
class WeightInteractor(
    private val weightRepo: WeightResultRepository,
    private val daysRepo: DaysRepository,
    private val prefsRepo: UserPreferencesRepository
) {
    suspend fun addWeight(weight: WeightResult) = asContentFlow {
        // 1. Save weight
        val savedWeight = weightRepo.putWeight(weight)
        
        // 2. Check if it triggers achievements
        val target = prefsRepo.observeTargetWeight().first()
        if (weight.value < target) {
            // 3. Update related data
            daysRepo.incrementCheatDays(1)
        }
        
        savedWeight
    }
}
```

### Pattern: User Context Injection

```kotlin
// Inject user-specific data through repositories
class WeightRoomSaver(
    private val weightDao: WeightDao,
    private val userRepository: UserRepository
) : ManyItemsCacheSaver<Long, WeightResult> {
    
    override suspend fun get(): List<WeightResult>? {
        val userId = userRepository.getCurrentUser().id  // Current user context
        return weightDao.observeWeights(userId).firstOrNull()
    }
}
```

### Pattern: Feature Toggles and Configuration

```kotlin
// Use manager to dynamically swap implementations
@Provides
fun provideWeightDataSource(
    @ApiHost apiHost: String,
    localDataSource: Provider<WeightRoomDataSource>,
    remoteDataSource: Provider<WeightDataSourceImpl>
): WeightDataSource =
    when {
        apiHost == Api.LOCALHOST_API -> localDataSource.get()  // Local testing
        else -> remoteDataSource.get()  // Production with network
    }
```

---

## 9. QuickMVI Integration

For more details on the MVI Store pattern used in CheatDay, refer to:
- [QuickMVI GitHub Repository](https://github.com/mariuszmarzec/QuickMVI)
- Key concepts:
  - **Intent-based:** User actions trigger intents
  - **Reducer-based:** Intents produce state changes
  - **Side-effect aware:** Separate concerns between state and effects
  - **Lifecycle-bound:** Tied to ViewModel lifecycle

---

## 10. Framework-Agnostic Considerations

This architecture works with:
- **UI Frameworks:** Traditional Views (Activities/Fragments), Jetpack Compose
- **Navigation:** Jetpack Navigation, Conductor, Cicerone
- **Database:** Room, Realm, SQLCipher
- **Network:** Retrofit, Ktor Client, OkHttp

The domain and repository layers remain unchanged regardless of UI framework choice.

---

## Summary

The CheatDay clean architecture demonstrates:
1. **Separation of Concerns:** Clear boundaries between layers
2. **Reactive Design:** Flow-based data propagation
3. **Advanced Caching:** Multi-tier cache with network coordination
4. **Testability:** Each layer independently testable
5. **Scalability:** Generic patterns support feature growth
6. **Maintainability:** Framework changes don't affect business logic

Apply these patterns systematically for robust, testable Android applications.
