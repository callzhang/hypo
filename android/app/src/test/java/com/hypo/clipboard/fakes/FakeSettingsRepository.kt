package com.hypo.clipboard.fakes

import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.data.settings.UserSettings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

class FakeSettingsRepository(initial: UserSettings = UserSettings()) : SettingsRepository {
    private val settingsFlow = MutableStateFlow(initial)

    val lanSyncCalls = mutableListOf<Boolean>()
    val cloudSyncCalls = mutableListOf<Boolean>()
    val historyLimitCalls = mutableListOf<Int>()
    val plainTextCalls = mutableListOf<Boolean>()

    override val settings: Flow<UserSettings> = settingsFlow.asStateFlow()

    override suspend fun setLanSyncEnabled(enabled: Boolean) {
        lanSyncCalls += enabled
        settingsFlow.value = settingsFlow.value.copy(lanSyncEnabled = enabled)
    }

    override suspend fun setCloudSyncEnabled(enabled: Boolean) {
        cloudSyncCalls += enabled
        settingsFlow.value = settingsFlow.value.copy(cloudSyncEnabled = enabled)
    }

    override suspend fun setHistoryLimit(limit: Int) {
        historyLimitCalls += limit
        settingsFlow.value = settingsFlow.value.copy(historyLimit = limit)
    }

    override suspend fun setPlainTextModeEnabled(enabled: Boolean) {
        plainTextCalls += enabled
        settingsFlow.value = settingsFlow.value.copy(plainTextModeEnabled = enabled)
    }

    fun emit(settings: UserSettings) {
        settingsFlow.value = settings
    }
}
