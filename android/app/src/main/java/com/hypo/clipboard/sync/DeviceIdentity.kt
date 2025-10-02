package com.hypo.clipboard.sync

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

private const val PREF_FILE = "hypo_device_identity"
private const val KEY_DEVICE_ID = "device_id"

@Singleton
class DeviceIdentity @Inject constructor(
    @ApplicationContext context: Context
) {
    private val prefs = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE)

    val deviceId: String by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        prefs.getString(KEY_DEVICE_ID, null) ?: generateAndPersist()
    }

    private fun generateAndPersist(): String {
        val value = "android-${UUID.randomUUID()}"
        prefs.edit().putString(KEY_DEVICE_ID, value).apply()
        return value
    }
}
