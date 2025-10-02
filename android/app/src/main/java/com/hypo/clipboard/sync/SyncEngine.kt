package com.hypo.clipboard.sync

import android.util.Base64
import com.hypo.clipboard.crypto.CryptoService
import com.hypo.clipboard.domain.model.ClipboardItem
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private const val BASE64_FLAGS = Base64.NO_WRAP

@Singleton
class SyncEngine @Inject constructor(
    private val cryptoService: CryptoService,
    private val keyStore: DeviceKeyStore,
    private val transport: SyncTransport,
    private val identity: DeviceIdentity
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    suspend fun registerKey(deviceId: String, key: ByteArray) {
        keyStore.saveKey(deviceId, key)
    }

    suspend fun removeKey(deviceId: String) {
        keyStore.deleteKey(deviceId)
    }

    suspend fun sendClipboard(item: ClipboardItem, targetDeviceId: String): SyncEnvelope {
        val key = keyStore.loadKey(targetDeviceId)
            ?: throw SyncEngineException.MissingKey(targetDeviceId)

        val payload = ClipboardPayload(
            contentType = item.type,
            dataBase64 = Base64.encodeToString(item.content.encodeToByteArray(), BASE64_FLAGS),
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

private fun ByteArray.toBase64(): String = Base64.encodeToString(this, BASE64_FLAGS)

private fun String.fromBase64(): ByteArray = Base64.decode(this, BASE64_FLAGS)
