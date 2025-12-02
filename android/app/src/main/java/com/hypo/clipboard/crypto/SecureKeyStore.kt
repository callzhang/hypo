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
        // Remove platform prefix if present
        val withoutPrefix = migrateDeviceId(deviceId)
        // Normalize to lowercase for consistent storage
        return withoutPrefix.lowercase()
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
        
        // Try normalized ID first (primary lookup)
        var encoded = prefs.getString(normalizedId, null)
        
        if (encoded != null) {
            android.util.Log.d("SecureKeyStore", "✅ Found key using normalized ID: $normalizedId (original: $deviceId)")
            return@withContext Base64.decode(encoded, Base64.DEFAULT)
        }
        
        // Fallback: Try original device ID (for backward compatibility with old keys)
        if (deviceId != normalizedId) {
            encoded = prefs.getString(deviceId, null)
            if (encoded != null) {
                android.util.Log.d("SecureKeyStore", "🔄 Found key using original ID (fallback): $deviceId")
                // Migrate to normalized ID for future lookups
                prefs.edit()
                    .putString(normalizedId, encoded)
                    .remove(deviceId)
                    .commit()
                return@withContext Base64.decode(encoded, Base64.DEFAULT)
            }
        }
        
        // Fallback: Try with platform prefix (for backward compatibility)
        if (!deviceId.startsWith("macos-") && !deviceId.startsWith("android-")) {
            // Try with "macos-" prefix
            encoded = prefs.getString("macos-$deviceId", null)
            if (encoded != null) {
                android.util.Log.d("SecureKeyStore", "🔄 Found key using old format: macos-$deviceId")
                // Migrate to normalized ID
                prefs.edit()
                    .putString(normalizedId, encoded)
                    .remove("macos-$deviceId")
                    .commit()
                return@withContext Base64.decode(encoded, Base64.DEFAULT)
            }
            
            // Try with "android-" prefix
            encoded = prefs.getString("android-$deviceId", null)
            if (encoded != null) {
                android.util.Log.d("SecureKeyStore", "🔄 Found key using old format: android-$deviceId")
                // Migrate to normalized ID
                prefs.edit()
                    .putString(normalizedId, encoded)
                    .remove("android-$deviceId")
                    .commit()
                return@withContext Base64.decode(encoded, Base64.DEFAULT)
            }
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
        val allKeys = prefs.all.keys.toList()
        val migratedKeys = mutableListOf<String>()
        
        // Migrate device IDs from old format (with prefix) to new format (pure UUID)
        allKeys.forEach { oldKey ->
            val newKey = migrateDeviceId(oldKey)
            if (newKey != oldKey) {
                // Key needs migration - copy value to new key and remove old key
                val value = prefs.getString(oldKey, null)
                if (value != null) {
                    prefs.edit()
                        .putString(newKey, value)
                        .remove(oldKey)
                        .commit()
                    android.util.Log.d("SecureKeyStore", "🔄 Migrated device ID: $oldKey -> $newKey")
                }
            }
            migratedKeys.add(newKey)
        }
        
        migratedKeys
    }
    
    /**
     * Migrates device ID from old format (with prefix) to new format (pure UUID).
     * Old format: "macos-{UUID}" or "android-{UUID}"
     * New format: "{UUID}" (pure UUID)
     */
    private fun migrateDeviceId(deviceId: String): String {
        return when {
            deviceId.startsWith("macos-") -> deviceId.removePrefix("macos-")
            deviceId.startsWith("android-") -> deviceId.removePrefix("android-")
            else -> deviceId  // Already in new format or unknown format
        }
    }
}
