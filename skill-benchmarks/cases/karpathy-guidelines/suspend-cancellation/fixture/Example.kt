package example

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

interface Repository {
    suspend fun load(): Data
}

data class Data(val value: String)

sealed interface UiState {
    data class Data(val value: example.Data) : UiState
    data class Error(val message: String) : UiState
}

suspend fun loadForUi(repository: Repository): UiState =
    try {
        UiState.Data(repository.load())
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (exception: Exception) {
        currentCoroutineContext().ensureActive()
        UiState.Error(exception.message ?: "Could not load data")
    }
