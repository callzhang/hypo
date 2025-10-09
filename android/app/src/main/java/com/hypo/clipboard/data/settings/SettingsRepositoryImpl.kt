package com.hypo.clipboard.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

@Singleton
class SettingsRepositoryImpl @Inject constructor(
    private val dataStore: DataStore<Preferences>
) : SettingsRepository {

    override val settings: Flow<UserSettings> = dataStore.data.map { preferences ->
        UserSettings(
            lanSyncEnabled = preferences[Keys.LAN_SYNC_ENABLED] ?: true,
            cloudSyncEnabled = preferences[Keys.CLOUD_SYNC_ENABLED] ?: true,
            historyLimit = preferences[Keys.HISTORY_LIMIT] ?: UserSettings.DEFAULT_HISTORY_LIMIT,
            autoDeleteDays = preferences[Keys.AUTO_DELETE_DAYS] ?: UserSettings.DEFAULT_AUTO_DELETE_DAYS
        )
    }

    override suspend fun setLanSyncEnabled(enabled: Boolean) {
        dataStore.edit { prefs -> prefs[Keys.LAN_SYNC_ENABLED] = enabled }
    }

    override suspend fun setCloudSyncEnabled(enabled: Boolean) {
        dataStore.edit { prefs -> prefs[Keys.CLOUD_SYNC_ENABLED] = enabled }
    }

    override suspend fun setHistoryLimit(limit: Int) {
        val clamped = limit.coerceIn(UserSettings.MIN_HISTORY_LIMIT, UserSettings.MAX_HISTORY_LIMIT)
        dataStore.edit { prefs -> prefs[Keys.HISTORY_LIMIT] = clamped }
    }

    override suspend fun setAutoDeleteDays(days: Int) {
        val clamped = days.coerceIn(UserSettings.MIN_AUTO_DELETE_DAYS, UserSettings.MAX_AUTO_DELETE_DAYS)
        dataStore.edit { prefs -> prefs[Keys.AUTO_DELETE_DAYS] = clamped }
    }

    private object Keys {
        val LAN_SYNC_ENABLED = booleanPreferencesKey("lan_sync_enabled")
        val CLOUD_SYNC_ENABLED = booleanPreferencesKey("cloud_sync_enabled")
        val HISTORY_LIMIT = intPreferencesKey("history_limit")
        val AUTO_DELETE_DAYS = intPreferencesKey("auto_delete_days")
    }
}
