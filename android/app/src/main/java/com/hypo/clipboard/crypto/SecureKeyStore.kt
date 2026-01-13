package com.hypo.clipboard.crypto

import android.content.Context
import android.util.Base64
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.hypo.clipboard.sync.DeviceKeyStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val PREF_FILE = "hypo_keys"

class SecureKeyStore @Inject constructor(
    @ApplicationContext private val context: Context
) : DeviceKeyStore {
    private val prefs by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            PREF_FILE,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    /**
     * Normalizes device ID for consistent storage and lookup.
     * - Converts to lowercase
     * - Removes platform prefix if present (macos-/android-)
     * - Returns pure UUID in lowercase
     */
    private fun normalizeDeviceId(deviceId: String): String {
        // Normalize to lowercase for consistent storage
        return deviceId.lowercase()
    }

    override suspend fun saveKey(deviceId: String, key: ByteArray) {
        withContext(Dispatchers.IO) {
            val normalizedId = normalizeDeviceId(deviceId)
            val encoded = Base64.encodeToString(key, Base64.NO_WRAP)
            prefs.edit().putString(normalizedId, encoded).commit()
            android.util.Log.d("SecureKeyStore", "💾 Saved key for device: $normalizedId (original: $deviceId)")
        }
    }

    override suspend fun loadKey(deviceId: String): ByteArray? = withContext(Dispatchers.IO) {
        // Normalize device ID for consistent lookup
        val normalizedId = normalizeDeviceId(deviceId)
        
        val encoded = prefs.getString(normalizedId, null)
        
        if (encoded != null) {
            return@withContext Base64.decode(encoded, Base64.DEFAULT)
        }
        
        // Not found
        android.util.Log.d("SecureKeyStore", "❌ Key not found for device: $normalizedId (original: $deviceId)")
        null
    }

    override suspend fun deleteKey(deviceId: String) {
        withContext(Dispatchers.IO) {
            val normalizedId = normalizeDeviceId(deviceId)
            prefs.edit().remove(normalizedId).commit()
            // Also try to remove original format for cleanup
            if (deviceId != normalizedId) {
                prefs.edit().remove(deviceId).commit()
            }
        }
    }

    override suspend fun getAllDeviceIds(): List<String> = withContext(Dispatchers.IO) {
        prefs.all.keys.toList()
    }
    

}
