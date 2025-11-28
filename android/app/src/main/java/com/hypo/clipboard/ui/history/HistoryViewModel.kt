package com.hypo.clipboard.ui.history

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.domain.model.ClipboardItem
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HistoryViewModel @Inject constructor(
    private val repository: ClipboardRepository,
    private val settingsRepository: SettingsRepository,
    private val deviceIdentity: com.hypo.clipboard.sync.DeviceIdentity,
    private val transportManager: com.hypo.clipboard.transport.TransportManager
) : ViewModel() {

    private val _state = MutableStateFlow(HistoryUiState())
    val state: StateFlow<HistoryUiState> = _state.asStateFlow()
    private val searchQuery = MutableStateFlow("")
    private val historyItems = repository.observeHistory(limit = MAX_HISTORY_ITEMS)
        .flowOn(Dispatchers.IO)
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(5000),
            initialValue = emptyList()
        )
    
    val currentDeviceId: String get() = deviceIdentity.deviceId

    init {
        observeHistory()
    }

    private fun observeHistory() {
        viewModelScope.launch {
            android.util.Log.d("HistoryViewModel", "📋 Starting to observe history...")
            combine(
                historyItems,
                settingsRepository.settings,
                searchQuery,
                transportManager.cloudConnectionState
            ) { items, settings, query, connectionState ->
                android.util.Log.d("HistoryViewModel", "📋 History Flow emitted: ${items.size} items, limit=${settings.historyLimit}, query='$query'")
                // Apply limit in ViewModel (Room query no longer has LIMIT to ensure Flow emits)
                val limited = items.take(settings.historyLimit)
                val filtered = if (query.isBlank()) {
                    limited
                } else {
                    limited.filter { item ->
                        item.preview.contains(query, ignoreCase = true) ||
                            item.content.contains(query, ignoreCase = true)
                    }
                }
                android.util.Log.d("HistoryViewModel", "📋 Filtered to ${filtered.size} items, first item: ${filtered.firstOrNull()?.preview?.take(30)}")
                HistoryUiState(
                    items = filtered,
                    query = query,
                    totalItems = limited.size,
                    historyLimit = settings.historyLimit,
                    connectionState = connectionState
                )
            }.collect { uiState ->
                android.util.Log.d("HistoryViewModel", "📋 UI state updated: ${uiState.items.size} items, first: ${uiState.items.firstOrNull()?.preview?.take(30)}")
                _state.value = uiState
            }
        }
    }
    
    fun refresh() {
        android.util.Log.d("HistoryViewModel", "🔄 Manual refresh triggered")
        // Trigger a refresh by updating search query (this will cause combine to re-evaluate)
        val currentQuery = searchQuery.value
        searchQuery.value = currentQuery + " "  // Add space to trigger change
        searchQuery.value = currentQuery         // Restore original
    }

    fun clearHistory() {
        viewModelScope.launch {
            repository.clear()
        }
    }

    fun onQueryChange(query: String) {
        searchQuery.value = query
    }

    companion object {
        private const val MAX_HISTORY_ITEMS = 500
    }
}

data class HistoryUiState(
    val items: List<ClipboardItem> = emptyList(),
    val query: String = "",
    val totalItems: Int = 0,
    val historyLimit: Int = UserSettings.DEFAULT_HISTORY_LIMIT,
    val connectionState: com.hypo.clipboard.transport.ConnectionState = com.hypo.clipboard.transport.ConnectionState.Idle
)
