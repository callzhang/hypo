package com.hypo.clipboard.data.settings

data class UserSettings(
    val lanSyncEnabled: Boolean = true,
    val cloudSyncEnabled: Boolean = true,
    val historyLimit: Int = DEFAULT_HISTORY_LIMIT,
    val plainTextModeEnabled: Boolean = false  // Plain text sync (no encryption) - for debugging
) {
    companion object {
        const val MIN_HISTORY_LIMIT = 20
        const val MAX_HISTORY_LIMIT = 500
        const val HISTORY_STEP = 10
        const val DEFAULT_HISTORY_LIMIT = 200
    }
}
