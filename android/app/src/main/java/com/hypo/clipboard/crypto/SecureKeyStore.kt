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
        // Use case-insensitive check to handle uppercase prefixes like "MACOS-" or "ANDROID-"
        val lowerDeviceId = deviceId.lowercase()
        if (!lowerDeviceId.startsWith("macos-") && !lowerDeviceId.startsWith("android-")) {
            // Try with "macos-" prefix (case-insensitive lookup)
            // Check all stored keys for case-insensitive match
            val allKeys = prefs.all.keys
            val macosKey = allKeys.find { key ->
                val lowerKey = key.lowercase()
                lowerKey.startsWith("macos-") && lowerKey.removePrefix("macos-") == normalizedId
            }
            if (macosKey != null) {
                encoded = prefs.getString(macosKey, null)
                if (encoded != null) {
                    android.util.Log.d("SecureKeyStore", "🔄 Found key using old format (case-insensitive): $macosKey")
                    // Migrate to normalized ID
                    prefs.edit()
                        .putString(normalizedId, encoded)
                        .remove(macosKey)
                        .commit()
                    return@withContext Base64.decode(encoded, Base64.DEFAULT)
                }
            }
            
            // Try with "android-" prefix (case-insensitive lookup)
            val androidKey = allKeys.find { key ->
                val lowerKey = key.lowercase()
                lowerKey.startsWith("android-") && lowerKey.removePrefix("android-") == normalizedId
            }
            if (androidKey != null) {
                encoded = prefs.getString(androidKey, null)
                if (encoded != null) {
                    android.util.Log.d("SecureKeyStore", "🔄 Found key using old format (case-insensitive): $androidKey")
                    // Migrate to normalized ID
                    prefs.edit()
                        .putString(normalizedId, encoded)
                        .remove(androidKey)
                        .commit()
                    return@withContext Base64.decode(encoded, Base64.DEFAULT)
                }
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
     * Old format: "macos-{UUID}" or "android-{UUID}" (case-insensitive)
     * New format: "{UUID}" (pure UUID)
     * 
     * Uses case-insensitive prefix detection to handle uppercase prefixes like "MACOS-" or "ANDROID-"
     */
    private fun migrateDeviceId(deviceId: String): String {
        val lowerDeviceId = deviceId.lowercase()
        return when {
            lowerDeviceId.startsWith("macos-") -> {
                // Remove prefix case-insensitively - find the actual prefix length
                deviceId.substring("macos-".length)
            }
            lowerDeviceId.startsWith("android-") -> {
                // Remove prefix case-insensitively - find the actual prefix length
                deviceId.substring("android-".length)
            }
            else -> deviceId  // Already in new format or unknown format
        }
    }
}
