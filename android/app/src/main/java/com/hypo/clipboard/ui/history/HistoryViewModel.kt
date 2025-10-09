package com.hypo.clipboard.ui.history

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.domain.model.ClipboardItem
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HistoryViewModel @Inject constructor(
    private val repository: ClipboardRepository,
    private val settingsRepository: SettingsRepository
) : ViewModel() {

    private val _state = MutableStateFlow(HistoryUiState())
    val state: StateFlow<HistoryUiState> = _state.asStateFlow()
    private val searchQuery = MutableStateFlow("")

    init {
        observeHistory()
    }

    private fun observeHistory() {
        viewModelScope.launch {
            combine(
                repository.observeHistory(limit = MAX_HISTORY_ITEMS),
                settingsRepository.settings,
                searchQuery
            ) { items, settings, query ->
                val limited = items.take(settings.historyLimit)
                val filtered = if (query.isBlank()) {
                    limited
                } else {
                    limited.filter { item ->
                        item.preview.contains(query, ignoreCase = true) ||
                            item.content.contains(query, ignoreCase = true)
                    }
                }
                HistoryUiState(
                    items = filtered,
                    query = query,
                    totalItems = limited.size,
                    historyLimit = settings.historyLimit
                )
            }.collect { uiState ->
                _state.value = uiState
            }
        }
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
    val historyLimit: Int = UserSettings.DEFAULT_HISTORY_LIMIT
)
