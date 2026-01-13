package com.hypo.clipboard.sync

import com.hypo.clipboard.util.formattedAsKB
import com.hypo.clipboard.crypto.CryptoService
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.util.SizeConstants
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
    private val settingsRepository: com.hypo.clipboard.data.settings.SettingsRepository,
    private val storageManager: com.hypo.clipboard.data.local.StorageManager
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
                android.util.Log.v("SyncEngine", "✅ Key loaded: ${loadedKey.size.formattedAsKB()}")
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
            ClipboardType.IMAGE, ClipboardType.FILE -> {
                if (item.content.isNotEmpty()) {
                    item.content
                } else if (!item.localPath.isNullOrEmpty()) {
                    // Load from disk if content is empty but localPath exists
                    android.util.Log.d("SyncEngine", "📥 Loading attachment from disk: ${item.localPath}")
                    val bytes = storageManager.read(item.localPath)
                    if (bytes != null) {
                        base64Encoder.encodeToString(bytes)
                    } else {
                        android.util.Log.e("SyncEngine", "❌ Failed to read attachment from ${item.localPath}")
                        ""
                    }
                } else {
                    ""
                }
            }
        }
        val payload = ClipboardPayload(
            contentType = item.type,
            dataBase64 = dataBase64,
            metadata = item.metadata ?: emptyMap(),
            compressed = true  // Always compress by default
        )
        val jsonString = json.encodeToString(payload)
        val jsonBytes = jsonString.encodeToByteArray()
        
        // Always compress the JSON payload before encryption
        val plaintext = compressGzip(jsonBytes)
        android.util.Log.v("SyncEngine", "🗜️ Compressed payload: ${jsonBytes.size.formattedAsKB()} -> ${plaintext.size.formattedAsKB()} (${String.format("%.1f", plaintext.size.toDouble() / jsonBytes.size * 100)}%)")

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
        
            android.util.Log.v("SyncEngine", "🔒 ENCRYPTED: ${item.content.take(20)}... | Ctxt: ${encrypted.ciphertext.size.formattedAsKB()} | CtxtB64: ${ctxt.length} chars (ends with ${ctxt.takeLast(6)}) | Nonce: ${nonce.length} | Tag: ${tag.length}")
            
            Triple(ctxt, nonce, tag)
        } else {
            // Plain text mode: use plaintext directly as "ciphertext", with empty nonce/tag
            android.util.Log.v("SyncEngine", "⚠️ PLAIN TEXT MODE: Sending unencrypted payload")
            android.util.Log.v("SyncEngine", "   Plaintext content: ${item.content.take(50)}")
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
                ),
                code = null,
                message = null,
                originalMessageId = null,
                targetDeviceId = null
            )
        )

        // Check payload size before sending (transport frame limit)
        // Estimate JSON-encoded size: base64 string + metadata overhead (~500 bytes for JSON structure)
        val estimatedPayloadSize = ciphertextBase64.length + 
            (item.metadata?.values?.sumOf { it.toString().length } ?: 0) + 
            500 // JSON structure overhead
        val maxTransportPayload = SizeConstants.MAX_TRANSPORT_PAYLOAD_BYTES
        
        if (estimatedPayloadSize > maxTransportPayload) {
            android.util.Log.w("SyncEngine", "⚠️ Payload too large for transport: ${estimatedPayloadSize.formattedAsKB()} (limit: ${maxTransportPayload.formattedAsKB()})")
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
        // Check if this is an error message
        if (envelope.type == MessageType.ERROR) {
            throw IllegalArgumentException("Cannot decode error message as ClipboardPayload")
        }
        
        // Check if this is a plain text message (empty nonce/tag indicates no encryption)
        val encryption = envelope.payload.encryption
        val ciphertext = envelope.payload.ciphertext
        if (encryption == null || ciphertext == null) {
            android.util.Log.e("SyncEngine", "❌ [DEBUG] Missing encryption or ciphertext: encryption=${encryption != null}, ciphertext=${ciphertext != null}")
            throw IllegalArgumentException("Missing encryption or ciphertext in payload")
        }
        
        val isPlainText = encryption.nonce.isEmpty() || encryption.tag.isEmpty()
        
        val decoded = if (isPlainText) {
            android.util.Log.w("SyncEngine", "⚠️ PLAIN TEXT MODE: Receiving unencrypted payload")
            // Decode base64-encoded plaintext directly
            val plaintextBytes = ciphertext.fromBase64()
            // Always decompress (all payloads are compressed by default)
            val decompressed = decompressGzip(plaintextBytes)
            android.util.Log.v("SyncEngine", "🗜️ Decompressed plaintext payload: ${plaintextBytes.size.formattedAsKB()} -> ${decompressed.size.formattedAsKB()}")
            decompressed.decodeToString()
        } else {
            val deviceId = envelope.payload.deviceId
            if (deviceId == null) {
                throw IllegalArgumentException("Missing deviceId in payload")
            }
            // Key lookup handles normalization internally - no need to normalize here
            // The key is stored under the sender's device ID (macOS device ID in this case)
            android.util.Log.d("SyncEngine", "🔓 DECODING: deviceId=$deviceId (sender's device ID)")
            android.util.Log.v("SyncEngine", "🔑 Looking up key for sender device: $deviceId")
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
            
            val keyHex = key.take(16).joinToString("") { "%02x".format(it) }
            val keyHex = key.take(16).joinToString("") { "%02x".format(it) }
            android.util.Log.v("SyncEngine", "✅ Key loaded: ${key.size.formattedAsKB()} for $deviceId | KeyHex(16): $keyHex")

            val ciphertextBytes = try {
                ciphertext.fromBase64()
            } catch (e: Exception) {
                android.util.Log.e("SyncEngine", "❌ [DEBUG] Base64 decode failed for ciphertext: ${e.message}", e)
                throw e
            }
            val nonce = try {
                encryption.nonce.fromBase64()
            } catch (e: Exception) {
                android.util.Log.e("SyncEngine", "❌ [DEBUG] Base64 decode failed for nonce: ${e.message}", e)
                throw e
            }
            val tag = try {
                encryption.tag.fromBase64()
            } catch (e: Exception) {
                android.util.Log.e("SyncEngine", "❌ [DEBUG] Base64 decode failed for tag: ${e.message}", e)
                throw e
            }
            
            // Normalize device ID to lowercase for AAD to match macOS encryption
            // macOS encrypts with entry.deviceId (already lowercase) as AAD
            val normalizedDeviceId = deviceId.lowercase()
            val aad = normalizedDeviceId.encodeToByteArray()
            val aadHex = aad.take(50).joinToString("") { "%02x".format(it) }

            val normalizedDeviceId = deviceId.lowercase()
            val aad = normalizedDeviceId.encodeToByteArray()
            val aadHex = aad.take(50).joinToString("") { "%02x".format(it) }

            android.util.Log.v("SyncEngine", "🔓 DECRYPTING: Key=${key.size.formattedAsKB()} | Ctxt=${ciphertextBytes.size.formattedAsKB()} | Nonce=${nonce.size.formattedAsKB()} | Tag=${tag.size.formattedAsKB()} | AAD=${aad.size.formattedAsKB()} ($aadHex)")
            val decrypted = try {
                cryptoService.decrypt(
                    encrypted = com.hypo.clipboard.crypto.EncryptedData(
                        ciphertext = ciphertextBytes,
                        nonce = nonce,
                        tag = tag
                    ),
                    key = key,
                    aad = aad
                )
            } catch (e: java.security.GeneralSecurityException) {
                android.util.Log.e("SyncEngine", "❌ Decryption failed in cryptoService.decrypt(): ${e.javaClass.simpleName}: ${e.message}")
                android.util.Log.e("SyncEngine", "   Device ID: $deviceId (normalized: $normalizedDeviceId)")
                android.util.Log.e("SyncEngine", "   Key size: ${key.size.formattedAsKB()}")
                android.util.Log.e("SyncEngine", "   AAD: ${aad.decodeToString()} (${aad.size.formattedAsKB()})")
                android.util.Log.e("SyncEngine", "   Ciphertext: ${ciphertextBytes.size.formattedAsKB()}")
                android.util.Log.e("SyncEngine", "   Nonce: ${nonce.size.formattedAsKB()}")
                android.util.Log.e("SyncEngine", "   Tag: ${tag.size.formattedAsKB()}")
                throw e
            }
            android.util.Log.d("SyncEngine", "✅ Decryption successful: ${decrypted.size.formattedAsKB()}")
            
            // Always decompress (all payloads are compressed by default)
            val decompressed = decompressGzip(decrypted)
            android.util.Log.v("SyncEngine", "🗜️ Decompressed payload: ${decrypted.size.formattedAsKB()} -> ${decompressed.size.formattedAsKB()}")
            decompressed.decodeToString()
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

/**
 * Compress data using gzip
 */
private fun compressGzip(data: ByteArray): ByteArray {
    val outputStream = java.io.ByteArrayOutputStream()
    val gzipOutputStream = java.util.zip.GZIPOutputStream(outputStream)
    gzipOutputStream.write(data)
    gzipOutputStream.close()
    return outputStream.toByteArray()
}

/**
 * Decompress gzip-compressed data
 */
private fun decompressGzip(data: ByteArray): ByteArray {
    val inputStream = java.io.ByteArrayInputStream(data)
    val gzipInputStream = java.util.zip.GZIPInputStream(inputStream)
    return gzipInputStream.readBytes()
}
