package com.hypo.clipboard.sync

import com.hypo.clipboard.crypto.CryptoService
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import java.util.Base64

private val base64Encoder = Base64.getEncoder().withoutPadding()
private val base64Decoder = Base64.getDecoder()

@Singleton
class SyncEngine @Inject constructor(
    private val cryptoService: CryptoService,
    private val keyStore: DeviceKeyStore,
    private val transport: SyncTransport,
    private val identity: DeviceIdentity,
    private val settingsRepository: com.hypo.clipboard.data.settings.SettingsRepository
) {
    @OptIn(ExperimentalSerializationApi::class)
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        namingStrategy = JsonNamingStrategy.SnakeCase
    }

    suspend fun registerKey(deviceId: String, key: ByteArray) {
        keyStore.saveKey(deviceId, key)
    }

    suspend fun removeKey(deviceId: String) {
        keyStore.deleteKey(deviceId)
    }

    suspend fun sendClipboard(item: ClipboardItem, targetDeviceId: String): SyncEnvelope {
        // Check if plain text mode is enabled
        val plainTextMode = settingsRepository.settings.first().plainTextModeEnabled
        
        if (plainTextMode) {
            android.util.Log.w("SyncEngine", "⚠️ PLAIN TEXT MODE: Sending without encryption")
        }
        
        // Step 3: Verify keys loaded for sync (Issue 2b checklist)
        android.util.Log.d("SyncEngine", "🔑 Loading key for device: $targetDeviceId")
        
        val key = if (!plainTextMode) {
            val loadedKey = keyStore.loadKey(targetDeviceId)
            if (loadedKey == null) {
                android.util.Log.e("SyncEngine", "❌ No key found for $targetDeviceId")
                val availableKeys = try {
                    keyStore.getAllDeviceIds()
                } catch (e: Exception) {
                    emptyList<String>()
                }
                android.util.Log.e("SyncEngine", "📋 Available keys in store: $availableKeys")
                android.util.Log.e("SyncEngine", "🔍 Trying to find matching key...")
                // Try case-insensitive and partial matching
                val matchingKey = availableKeys.find { 
                    it.equals(targetDeviceId, ignoreCase = true) || 
                    it.contains(targetDeviceId, ignoreCase = true) ||
                    targetDeviceId.contains(it, ignoreCase = true)
                }
                if (matchingKey != null) {
                    android.util.Log.w("SyncEngine", "⚠️ Found similar key: $matchingKey (requested: $targetDeviceId)")
                    android.util.Log.w("SyncEngine", "💡 Device ID mismatch! Key saved as '$matchingKey' but sync target is '$targetDeviceId'")
                }
                throw SyncEngineException.MissingKey(targetDeviceId)
            } else {
                android.util.Log.d("SyncEngine", "✅ Key loaded: ${loadedKey.size} bytes")
                loadedKey
            }
        } else {
            // Plain text mode: no key needed
            android.util.Log.d("SyncEngine", "⚠️ Plain text mode: Skipping key loading")
            null
        }

        val dataBase64 = when (item.type) {
            ClipboardType.TEXT, ClipboardType.LINK ->
                base64Encoder.encodeToString(item.content.encodeToByteArray())
            ClipboardType.IMAGE, ClipboardType.FILE -> item.content
        }
        val payload = ClipboardPayload(
            contentType = item.type,
            dataBase64 = dataBase64,
            metadata = item.metadata ?: emptyMap()
        )
        val plaintext = json.encodeToString(payload).encodeToByteArray()

        val (ciphertextBase64, nonceBase64, tagBase64) = if (!plainTextMode && key != null) {
            val aad = identity.deviceId.encodeToByteArray()
            val encrypted = cryptoService.encrypt(plaintext, key, aad)

            val ctxt = encrypted.ciphertext.toBase64()
            val nonce = encrypted.nonce.toBase64()
            val tag = encrypted.tag.toBase64()
        
            android.util.Log.d("SyncEngine", "🔍 ENCODING DEBUG:")
            android.util.Log.d("SyncEngine", "   Original content: ${item.content.take(50)}")
            android.util.Log.d("SyncEngine", "   Ciphertext length: ${encrypted.ciphertext.size} bytes")
            android.util.Log.d("SyncEngine", "   Ciphertext base64 (full): $ctxt")
            android.util.Log.d("SyncEngine", "   Nonce base64: $nonce")
            android.util.Log.d("SyncEngine", "   Tag base64: $tag")
            android.util.Log.d("SyncEngine", "   Base64 encoder: withoutPadding=${base64Encoder.withoutPadding()}")
            android.util.Log.d("SyncEngine", "   Ciphertext base64 length: ${ctxt.length} chars")
            android.util.Log.d("SyncEngine", "   Ciphertext base64 ends with: ${ctxt.takeLast(10)}")
            
            Triple(ctxt, nonce, tag)
        } else {
            // Plain text mode: use plaintext directly as "ciphertext", with empty nonce/tag
            android.util.Log.d("SyncEngine", "⚠️ PLAIN TEXT MODE: Sending unencrypted payload")
            android.util.Log.d("SyncEngine", "   Plaintext content: ${item.content.take(50)}")
            Triple(base64Encoder.encodeToString(plaintext), "", "")
        }
        
        val envelope = SyncEnvelope(
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = item.type,
                ciphertext = ciphertextBase64,
                deviceId = identity.deviceId,
                deviceName = identity.deviceName,
                target = targetDeviceId,
                encryption = EncryptionMetadata(
                    nonce = nonceBase64,
                    tag = tagBase64
                )
            )
        )

        // Check payload size before sending (transport limit is 10MB)
        // Estimate JSON-encoded size: base64 string + metadata overhead (~500 bytes for JSON structure)
        val estimatedPayloadSize = ciphertextBase64.length + 
            (item.metadata?.values?.sumOf { it.toString().length } ?: 0) + 
            500 // JSON structure overhead
        val maxTransportPayload = 10 * 1024 * 1024 // 10MB limit from TransportFrameCodec
        
        if (estimatedPayloadSize > maxTransportPayload) {
            android.util.Log.w("SyncEngine", "⚠️ Payload too large for transport: ${estimatedPayloadSize} bytes (limit: ${maxTransportPayload} bytes)")
            android.util.Log.w("SyncEngine", "⚠️ Skipping sync for ${item.type} content (base64 length: ${ciphertextBase64.length} chars)")
            throw TransportPayloadTooLargeException(
                "Payload size ${estimatedPayloadSize} bytes exceeds transport limit of ${maxTransportPayload} bytes"
            )
        }

        android.util.Log.d("SyncEngine", "📤 Calling transport.send() for device: $targetDeviceId (payload size: ~${estimatedPayloadSize} bytes)")
        try {
            transport.send(envelope)
            android.util.Log.d("SyncEngine", "✅ transport.send() completed successfully")
        } catch (e: com.hypo.clipboard.transport.ws.TransportFrameException) {
            // Re-throw as TransportPayloadTooLargeException for better error handling
            android.util.Log.e("SyncEngine", "❌ Transport frame error: ${e.message}", e)
            throw TransportPayloadTooLargeException("Payload exceeds transport frame size limit: ${e.message}", e)
        } catch (e: Exception) {
            // transport implementations (WebSocket, etc.) can throw IOException/timeout here;
            // we surface the error but avoid crashing the caller without context.
            android.util.Log.e("SyncEngine", "❌ transport.send() failed: ${e.message}", e)
            throw e
        }
        return envelope
    }

    suspend fun decode(envelope: SyncEnvelope): ClipboardPayload {
        // Check if this is a plain text message (empty nonce/tag indicates no encryption)
        val isPlainText = envelope.payload.encryption.nonce.isEmpty() || envelope.payload.encryption.tag.isEmpty()
        
        val decoded = if (isPlainText) {
            android.util.Log.w("SyncEngine", "⚠️ PLAIN TEXT MODE: Receiving unencrypted payload")
            // Decode base64-encoded plaintext directly
            val plaintext = envelope.payload.ciphertext.fromBase64()
            plaintext.decodeToString()
        } else {
            val key = keyStore.loadKey(envelope.payload.deviceId)
                ?: throw SyncEngineException.MissingKey(envelope.payload.deviceId)

            val ciphertext = envelope.payload.ciphertext.fromBase64()
            val nonce = envelope.payload.encryption.nonce.fromBase64()
            val tag = envelope.payload.encryption.tag.fromBase64()
            val aad = envelope.payload.deviceId.encodeToByteArray()

            val decrypted = cryptoService.decrypt(
                encrypted = com.hypo.clipboard.crypto.EncryptedData(
                    ciphertext = ciphertext,
                    nonce = nonce,
                    tag = tag
                ),
                key = key,
                aad = aad
            )
            decrypted.decodeToString()
        }

        return withContext(Dispatchers.Default) {
            json.decodeFromString(ClipboardPayload.serializer(), decoded)
        }
    }
}

sealed class SyncEngineException(message: String) : Exception(message) {
    class MissingKey(deviceId: String) : SyncEngineException("No symmetric key registered for $deviceId")
}

private fun ByteArray.toBase64(): String = base64Encoder.encodeToString(this)

private fun String.fromBase64(): ByteArray = base64Decoder.decode(this)
