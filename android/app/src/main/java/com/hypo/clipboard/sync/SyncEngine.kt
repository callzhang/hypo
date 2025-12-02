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
import java.util.UUID
import java.time.Instant

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
        
        // Key lookup handles normalization internally - no need to normalize here
        android.util.Log.d("SyncEngine", "🔑 Loading key for device: $targetDeviceId")
        
        val key = if (!plainTextMode) {
            val loadedKey = keyStore.loadKey(targetDeviceId)
            if (loadedKey == null) {
                android.util.Log.e("SyncEngine", "❌ No key found for device: $targetDeviceId")
                val availableKeys = try {
                    keyStore.getAllDeviceIds()
                } catch (e: Exception) {
                    emptyList<String>()
                }
                android.util.Log.e("SyncEngine", "📋 Available keys in store: $availableKeys")
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
            // Normalize device ID to lowercase for AAD to match decryption (macOS uses lowercase)
            // Normalize sender device ID to lowercase for AAD to match macOS encryption
            // macOS encrypts with entry.deviceId (already lowercase) as AAD
            val normalizedSenderDeviceId = identity.deviceId.lowercase()
            val aad = normalizedSenderDeviceId.encodeToByteArray()
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
            id = UUID.randomUUID().toString(),
            timestamp = Instant.now().toString(),
            version = "1.0",
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = item.type,
                ciphertext = ciphertextBase64,
                deviceId = identity.deviceId.lowercase(), // Normalize to lowercase for consistent matching
                deviceName = identity.deviceName,
                target = targetDeviceId, // Target device ID (key lookup handles normalization)
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

        try {
            transport.send(envelope)
            android.util.Log.d("SyncEngine", "✅ Sync sent to $targetDeviceId (~${estimatedPayloadSize / 1024}KB)")
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
            val deviceId = envelope.payload.deviceId
            android.util.Log.d("SyncEngine", "🔓 DECODING: deviceId=$deviceId")
            
            // Key lookup handles normalization internally - no need to normalize here
            val key = keyStore.loadKey(deviceId)
            if (key == null) {
                android.util.Log.e("SyncEngine", "❌ Key not found for device: $deviceId")
                val availableKeys = try {
                    keyStore.getAllDeviceIds()
                } catch (e: Exception) {
                    emptyList<String>()
                }
                android.util.Log.e("SyncEngine", "📋 Available keys in store: $availableKeys")
                throw SyncEngineException.MissingKey(deviceId)
            }
            
            android.util.Log.d("SyncEngine", "✅ Key loaded: ${key.size} bytes for device: $deviceId")

            val ciphertext = envelope.payload.ciphertext.fromBase64()
            val nonce = envelope.payload.encryption.nonce.fromBase64()
            val tag = envelope.payload.encryption.tag.fromBase64()
            
            android.util.Log.d("SyncEngine", "🔓 Decryption params: ciphertext=${ciphertext.size} bytes, nonce=${nonce.size} bytes, tag=${tag.size} bytes")
            
            // Normalize device ID to lowercase for AAD to match macOS encryption
            // macOS encrypts with entry.deviceId (already lowercase) as AAD
            val normalizedDeviceId = deviceId.lowercase()
            val aad = normalizedDeviceId.encodeToByteArray()
            android.util.Log.d("SyncEngine", "🔓 AAD: deviceId=$normalizedDeviceId (${aad.size} bytes)")

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
