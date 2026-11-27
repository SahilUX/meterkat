package com.sahil.meterkat.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.sahil.meterkat.data.MeterkatRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow

/** Keeps repository jobs alive through configuration changes, while polling only in foreground. */
class MeterkatViewModel(val repository: MeterkatRepository) : ViewModel() {
    val state = repository.state
    private var foreground: Job? = null
    private val messages = Channel<String>(Channel.BUFFERED)
    val events = messages.receiveAsFlow()

    init {
        perform { repository.initialize() }
    }

    fun foreground(active: Boolean) {
        foreground?.cancel()
        foreground =
            if (active)
                viewModelScope.launch {
                    repository.initialize()
                    while (isActive) {
                        try {
                            if (repository.state.value.clients.isNotEmpty()) repository.refresh()
                        } catch (e: CancellationException) {
                            throw e
                        } catch (_: Exception) {
                            messages.send("Couldn't refresh. Your saved usage is still available.")
                        }
                        delay(60_000)
                    }
                }
            else null
    }

    fun perform(block: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                block()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                messages.send(e.message ?: "Something went wrong.")
            }
        }
    }

    companion object {
        fun factory(repository: MeterkatRepository) =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    MeterkatViewModel(repository) as T
            }
    }
}
