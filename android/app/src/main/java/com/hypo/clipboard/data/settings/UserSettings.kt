package com.hypo.clipboard.data.settings

data class UserSettings(
    val lanSyncEnabled: Boolean = true,
    val cloudSyncEnabled: Boolean = true,
    val historyLimit: Int = DEFAULT_HISTORY_LIMIT,
    val autoDeleteDays: Int = DEFAULT_AUTO_DELETE_DAYS
) {
    companion object {
        const val MIN_HISTORY_LIMIT = 20
        const val MAX_HISTORY_LIMIT = 500
        const val HISTORY_STEP = 10
        const val MIN_AUTO_DELETE_DAYS = 0
        const val MAX_AUTO_DELETE_DAYS = 30
        const val DEFAULT_HISTORY_LIMIT = 200
        const val DEFAULT_AUTO_DELETE_DAYS = 30
    }
}
