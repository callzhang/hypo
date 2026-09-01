package com.hypo.clipboard.sync

import android.content.Context
import android.os.Build
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

private const val PREF_FILE = "hypo_device_identity"
private const val KEY_DEVICE_ID = "device_id"
private const val KEY_DEVICE_PLATFORM = "device_platform"
private const val KEY_DEVICE_NAME = "device_name"
private const val PLATFORM_ANDROID = "android"


@Singleton
class DeviceIdentity @Inject constructor(
    @ApplicationContext context: Context
) {
    private val prefs = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE)

    val deviceId: String by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        val stored = prefs.getString(KEY_DEVICE_ID, null)
        if (stored != null) {
            // Ensure platform is set
            if (prefs.getString(KEY_DEVICE_PLATFORM, null) == null) {
                prefs.edit().putString(KEY_DEVICE_PLATFORM, PLATFORM_ANDROID).apply()
            }
            stored
        } else {
            generateAndPersist()
        }
    }

    val platform: String by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        prefs.getString(KEY_DEVICE_PLATFORM, null) ?: run {
            prefs.edit().putString(KEY_DEVICE_PLATFORM, PLATFORM_ANDROID).apply()
            PLATFORM_ANDROID
        }
    }

    @Volatile
    private var cachedName: String? = null

    /**
     * What peers call this device.
     *
     * Defaults to the make and model, which is what the OS knows and rarely what
     * its owner would call it, so it can be renamed.
     */
    val deviceName: String
        get() = cachedName ?: synchronized(this) {
            cachedName ?: (prefs.getString(KEY_DEVICE_NAME, null) ?: defaultName()).also { cachedName = it }
        }

    /**
     * Renames this device.
     *
     * The name travels in the pairing handshake and in the Bonjour service, so
     * peers that are already paired keep showing the old one until they pair or
     * see this device advertise again. Nothing here can change what another
     * device has already stored.
     *
     * Returns the name that was actually kept: blank input is refused.
     */
    @Synchronized
    fun rename(newName: String): String {
        val sanitized = newName.replace(".local", "").trim()
        if (sanitized.isEmpty()) return deviceName

        prefs.edit().putString(KEY_DEVICE_NAME, sanitized).apply()
        cachedName = sanitized
        return sanitized
    }

    private fun defaultName(): String {
        val manufacturer = Build.MANUFACTURER.takeIf { it.isNotBlank() }?.replaceFirstChar(Char::uppercaseChar)
        val model = Build.MODEL
        return if (manufacturer == null || model.startsWith(manufacturer)) {
            model
        } else {
            "$manufacturer $model"
        }
    }

    private fun generateAndPersist(): String {
        val uuid = UUID.randomUUID().toString()
        prefs.edit()
            .putString(KEY_DEVICE_ID, uuid)
            .putString(KEY_DEVICE_PLATFORM, PLATFORM_ANDROID)
            .apply()
        return uuid
    }
}
