package example

interface Repository {
    suspend fun load(): Data
}

data class Data(val value: String)

sealed interface UiState {
    data class Data(val value: example.Data) : UiState
    data class Error(val message: String) : UiState
}

suspend fun loadForUi(repository: Repository): UiState =
    UiState.Data(repository.load())
