package com.hypo.clipboard.sync

import com.hypo.clipboard.crypto.CryptoService
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
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
    private val identity: DeviceIdentity
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
        // Step 3: Verify keys loaded for sync (Issue 2b checklist)
        android.util.Log.d("SyncEngine", "🔑 Loading key for device: $targetDeviceId")
        val key = keyStore.loadKey(targetDeviceId)
        if (key == null) {
            android.util.Log.e("SyncEngine", "❌ No key found for $targetDeviceId")
            val availableKeys = try {
                keyStore.getAllDeviceIds()
            } catch (e: Exception) {
                emptyList<String>()
            }
            android.util.Log.d("SyncEngine", "📋 Available keys: $availableKeys")
            throw SyncEngineException.MissingKey(targetDeviceId)
        } else {
            android.util.Log.d("SyncEngine", "✅ Key loaded: ${key.size} bytes")
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
        val aad = identity.deviceId.encodeToByteArray()

        val encrypted = cryptoService.encrypt(plaintext, key, aad)

        val envelope = SyncEnvelope(
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = item.type,
                ciphertext = encrypted.ciphertext.toBase64(),
                deviceId = identity.deviceId,
                deviceName = identity.deviceName,
                target = targetDeviceId,
                encryption = EncryptionMetadata(
                    nonce = encrypted.nonce.toBase64(),
                    tag = encrypted.tag.toBase64()
                )
            )
        )

        transport.send(envelope)
        return envelope
    }

    suspend fun decode(envelope: SyncEnvelope): ClipboardPayload {
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

        val decoded = decrypted.decodeToString()
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
