package com.hypo.clipboard.ui.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.transport.ConnectionState
import com.hypo.clipboard.transport.TransportManager
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

@HiltViewModel
class HomeViewModel @Inject constructor(
    private val repository: ClipboardRepository,
    private val transportManager: TransportManager
) : ViewModel() {

    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    init {
        observeState()
    }

    private fun observeState() {
        viewModelScope.launch {
            combine(
                repository.observeHistory(limit = HISTORY_SAMPLE_LIMIT).map { it.firstOrNull() },
                transportManager.cloudConnectionState  // Only show cloud server status in UI
            ) { latestItem, connectionState ->
                HomeUiState(
                    latestItem = latestItem,
                    connectionState = connectionState
                )
            }.collect { state ->
                _uiState.value = state
            }
        }
    }

    companion object {
        private const val HISTORY_SAMPLE_LIMIT = 25
    }
}

data class HomeUiState(
    val latestItem: ClipboardItem? = null,
    val connectionState: ConnectionState = ConnectionState.Idle
)
