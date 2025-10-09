package com.hypo.clipboard.data.settings

import kotlinx.coroutines.flow.Flow

interface SettingsRepository {
    val settings: Flow<UserSettings>

    suspend fun setLanSyncEnabled(enabled: Boolean)
    suspend fun setCloudSyncEnabled(enabled: Boolean)
    suspend fun setHistoryLimit(limit: Int)
    suspend fun setAutoDeleteDays(days: Int)
}
