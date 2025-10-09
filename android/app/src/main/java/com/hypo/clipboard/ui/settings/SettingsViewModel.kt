package com.hypo.clipboard.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsRepository: SettingsRepository,
    private val transportManager: TransportManager
) : ViewModel() {

    private val _state = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = _state.asStateFlow()

    init {
        observeState()
    }

    private fun observeState() {
        viewModelScope.launch {
            combine(settingsRepository.settings, transportManager.peers) { settings, peers ->
                SettingsUiState(
                    lanSyncEnabled = settings.lanSyncEnabled,
                    cloudSyncEnabled = settings.cloudSyncEnabled,
                    historyLimit = settings.historyLimit,
                    autoDeleteDays = settings.autoDeleteDays,
                    discoveredPeers = peers
                )
            }.collect { state ->
                _state.value = state
            }
        }
    }

    fun onLanSyncChanged(enabled: Boolean) {
        viewModelScope.launch { settingsRepository.setLanSyncEnabled(enabled) }
    }

    fun onCloudSyncChanged(enabled: Boolean) {
        viewModelScope.launch { settingsRepository.setCloudSyncEnabled(enabled) }
    }

    fun onHistoryLimitChanged(limit: Int) {
        viewModelScope.launch { settingsRepository.setHistoryLimit(limit) }
    }

    fun onAutoDeleteDaysChanged(days: Int) {
        viewModelScope.launch { settingsRepository.setAutoDeleteDays(days) }
    }
}

data class SettingsUiState(
    val lanSyncEnabled: Boolean = true,
    val cloudSyncEnabled: Boolean = true,
    val historyLimit: Int = UserSettings.DEFAULT_HISTORY_LIMIT,
    val autoDeleteDays: Int = UserSettings.DEFAULT_AUTO_DELETE_DAYS,
    val discoveredPeers: List<DiscoveredPeer> = emptyList()
)
