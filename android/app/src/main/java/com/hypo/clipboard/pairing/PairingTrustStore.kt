package com.hypo.clipboard.pairing

import android.content.Context
import android.util.Base64
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject

class PairingTrustStore @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val prefs = context.getSharedPreferences("pairing_trust", Context.MODE_PRIVATE)

    fun store(macDeviceId: String, publicKey: ByteArray) {
        val encoded = Base64.encodeToString(publicKey, Base64.NO_WRAP)
        prefs.edit().putString(macDeviceId, encoded).apply()
    }

    fun publicKey(macDeviceId: String): ByteArray? {
        val stored = prefs.getString(macDeviceId, null)
        return stored?.let { Base64.decode(it, Base64.DEFAULT) } ?: fallback(macDeviceId)
    }

    private fun fallback(macDeviceId: String): ByteArray? {
        val bootstrap = BOOTSTRAP_KEYS[macDeviceId] ?: return null
        return Base64.decode(bootstrap, Base64.DEFAULT)
    }

    companion object {
        private val BOOTSTRAP_KEYS = mapOf(
            // Placeholder bootstrap entry; in production this should be distributed securely
            "bootstrap-mac" to "r5zfO3iLz+yuPkP9/ufa9YcF+JaKuIgMnzE81s4K4Qs="
        )
    }
}
