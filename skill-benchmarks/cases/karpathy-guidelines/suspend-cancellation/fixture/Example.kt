package example

import kotlinx.coroutines.CancellationException

interface Repository {
    suspend fun load(): Data
}

data class Data(val value: String)

sealed interface UiState {
    data class Data(val value: example.Data) : UiState
    data class Error(val message: String) : UiState
}

suspend fun loadForUi(repository: Repository): UiState {
    try {
        return UiState.Data(repository.load())
    } catch (exception: Exception) {
        return UiState.Error(exception.message ?: "Could not load data")
    }
}
