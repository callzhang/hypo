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

    override suspend fun saveKey(deviceId: String, key: ByteArray) {
        withContext(Dispatchers.IO) {
            val encoded = Base64.encodeToString(key, Base64.NO_WRAP)
            prefs.edit().putString(deviceId, encoded).commit()
        }
    }

    override suspend fun loadKey(deviceId: String): ByteArray? = withContext(Dispatchers.IO) {
        // Try exact match first (as-is, no preprocessing)
        var encoded = prefs.getString(deviceId, null)
        
        // If not found and deviceId has prefix, try without prefix
        if (encoded == null && (deviceId.startsWith("macos-") || deviceId.startsWith("android-"))) {
            val migratedId = migrateDeviceId(deviceId)
            encoded = prefs.getString(migratedId, null)
            if (encoded != null) {
                android.util.Log.d("SecureKeyStore", "🔄 Found key using migrated ID: $deviceId -> $migratedId")
            }
        }
        
        // If still not found, try lowercase version for backward compatibility
        // (Old keys may have been stored as lowercase from PairingPayload)
        // UUIDs are case-insensitive, so this is safe
        if (encoded == null && deviceId.length == 36 && deviceId.matches(Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"))) {
            val lowercased = deviceId.lowercase()
            if (lowercased != deviceId) {
                encoded = prefs.getString(lowercased, null)
                if (encoded != null) {
                    android.util.Log.d("SecureKeyStore", "🔄 Found key using lowercase (backward compatibility): $deviceId -> $lowercased")
                }
            }
        }
        
        // If still not found, try old format (with prefix) for backward compatibility
        if (encoded == null && !deviceId.startsWith("macos-") && !deviceId.startsWith("android-")) {
            // Try with "macos-" prefix
            encoded = prefs.getString("macos-$deviceId", null)
            if (encoded != null) {
                android.util.Log.d("SecureKeyStore", "🔄 Found key using old format: macos-$deviceId")
                // Migrate it
                prefs.edit()
                    .putString(deviceId, encoded)
                    .remove("macos-$deviceId")
                    .commit()
            } else {
                // Try with "android-" prefix
                encoded = prefs.getString("android-$deviceId", null)
                if (encoded != null) {
                    android.util.Log.d("SecureKeyStore", "🔄 Found key using old format: android-$deviceId")
                    // Migrate it
                    prefs.edit()
                        .putString(deviceId, encoded)
                        .remove("android-$deviceId")
                        .commit()
                }
            }
        }
        
        encoded?.let { Base64.decode(it, Base64.DEFAULT) }
    }

    override suspend fun deleteKey(deviceId: String) {
        withContext(Dispatchers.IO) {
            prefs.edit().remove(deviceId).commit()
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
