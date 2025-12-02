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
        val encoded = prefs.getString(deviceId, null) ?: return@withContext null
        Base64.decode(encoded, Base64.DEFAULT)
    }

    override suspend fun deleteKey(deviceId: String) {
        withContext(Dispatchers.IO) {
            prefs.edit().remove(deviceId).commit()
        }
    }

    override suspend fun getAllDeviceIds(): List<String> = withContext(Dispatchers.IO) {
        prefs.all.keys.toList()
    }
}
