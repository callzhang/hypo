package com.hypo.clipboard.sync

import com.hypo.clipboard.crypto.CryptoService
import com.hypo.clipboard.data.local.StorageManager
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.fakes.FakeSettingsRepository
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.slot
import java.time.Instant
import java.util.Base64
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Test
import com.hypo.clipboard.sync.TransportPayloadTooLargeException
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SyncEngineTest {
    private val deviceKeyStore = mockk<DeviceKeyStore>()
    private val transport = mockk<SyncTransport>(relaxed = true)
    private val identity = mockk<DeviceIdentity> {
        every { deviceId } returns "android-device-123"
        every { deviceName } returns "Pixel"
    }
    private val settingsRepository = FakeSettingsRepository()
    private val storageManager = mockk<StorageManager>(relaxed = true)

    @Test
    fun encryptsClipboardPayloadsBeforeSending() = runTest {
        val nonce = ByteArray(12) { 0xAA.toByte() }
        val cryptoService = CryptoService { nonce }
        val key = ByteArray(32) { index -> index.toByte() }

        coEvery { deviceKeyStore.loadKey("mac-device") } returns key
        coEvery { transport.send(any()) } returns Unit

        val engine = SyncEngine(cryptoService, deviceKeyStore, transport, identity, settingsRepository, storageManager)
        val item = ClipboardItem(
            id = "clip-1",
            type = ClipboardType.TEXT,
            content = "Hello, Hypo!",
            preview = "Hello, Hypo!",
            metadata = mapOf("length" to "12"),
            deviceId = identity.deviceId,
            createdAt = Instant.parse("2024-03-21T12:30:45Z"),
            isPinned = false
        )

        val envelope = engine.sendClipboard(item, "mac-device")

        coVerify(exactly = 1) { transport.send(envelope) }
        assertEquals(MessageType.CLIPBOARD, envelope.type)
        assertEquals("mac-device", envelope.payload.target)
        assertEquals(identity.deviceId, envelope.payload.deviceId)

        val ciphertext = Base64.getDecoder().decode(envelope.payload.ciphertext)
        val encryption = requireNotNull(envelope.payload.encryption)
        val nonceValue = Base64.getDecoder().decode(encryption.nonce)
        assertContentEquals(nonce, nonceValue)
        // Ciphertext should not equal plaintext bytes
        val plaintext = "Hello, Hypo!".encodeToByteArray()
        assertNotEquals(plaintext.toList(), ciphertext.toList())
    }

    @Test
    fun decodeRestoresOriginalPayload() = runTest {
        val cryptoService = mockk<CryptoService>()
        val ciphertext = Base64.getEncoder().encodeToString("cipher".encodeToByteArray())
        val nonce = Base64.getEncoder().encodeToString(ByteArray(12) { 1 })
        val tag = Base64.getEncoder().encodeToString(ByteArray(16) { 2 })
        val payloadJson = "{\"content_type\":\"text\",\"data_base64\":\"${Base64.getEncoder().encodeToString("Hello".encodeToByteArray())}\",\"metadata\":{}}"
        val key = ByteArray(32) { 9 }

        coEvery { deviceKeyStore.loadKey("mac-device") } returns key
        val compressedPayload = gzip(payloadJson.encodeToByteArray())
        coEvery {
            cryptoService.decrypt(
                encrypted = any(),
                key = key,
                aad = "mac-device".encodeToByteArray()
            )
        } returns compressedPayload

        val envelope = SyncEnvelope(
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = ClipboardType.TEXT,
                ciphertext = ciphertext,
                deviceId = "mac-device",
                target = identity.deviceId,
                encryption = EncryptionMetadata(
                    nonce = nonce,
                    tag = tag
                )
            )
        )

        val engine = SyncEngine(cryptoService, deviceKeyStore, transport, identity, settingsRepository, storageManager)
        val payload = engine.decode(envelope)

        assertEquals(ClipboardType.TEXT, payload.contentType)
        val decodedData = Base64.getDecoder().decode(payload.dataBase64)
        assertContentEquals("Hello".encodeToByteArray(), decodedData)
    }

    @Test
    fun throwsWhenKeyMissing() = runTest {
        val cryptoService = mockk<CryptoService>(relaxed = true)
        coEvery { deviceKeyStore.loadKey(any()) } returns null
        coEvery { deviceKeyStore.getAllDeviceIds() } returns emptyList()
        val engine = SyncEngine(cryptoService, deviceKeyStore, transport, identity, settingsRepository, storageManager)

        val item = ClipboardItem(
            id = "clip",
            type = ClipboardType.TEXT,
            content = "Hello",
            preview = "Hello",
            metadata = null,
            deviceId = identity.deviceId,
            createdAt = Instant.now(),
            isPinned = false
        )

        assertFailsWith<SyncEngineException.MissingKey> {
            engine.sendClipboard(item, "mac-device")
        }

        val envelope = SyncEnvelope(
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = ClipboardType.TEXT,
                ciphertext = Base64.getEncoder().encodeToString("cipher".encodeToByteArray()),
                deviceId = "mac-device",
                encryption = EncryptionMetadata(
                    nonce = Base64.getEncoder().encodeToString(ByteArray(12)),
                    tag = Base64.getEncoder().encodeToString(ByteArray(16))
                )
            )
        )

        assertFailsWith<SyncEngineException.MissingKey> {
            engine.decode(envelope)
        }
    }

    @Test
    fun doesNotDoubleEncodeBinaryPayloads() = runTest {
        val cryptoService = mockk<CryptoService>()
        val key = ByteArray(32) { 5 }
        val rawBase64 = Base64.getEncoder().withoutPadding().encodeToString("image-bytes".encodeToByteArray())
        var capturedPlaintext: ByteArray? = null
        val plaintextSlot = io.mockk.slot<ByteArray>()

        coEvery { deviceKeyStore.loadKey("mac-device") } returns key
        coEvery {
            cryptoService.encrypt(
                plaintext = capture(plaintextSlot),
                key = key,
                aad = any()
            )
        } answers {
            capturedPlaintext = plaintextSlot.captured
            com.hypo.clipboard.crypto.EncryptedData(
                ciphertext = ByteArray(0),
                nonce = ByteArray(12),
                tag = ByteArray(16)
            )
        }
        coEvery { transport.send(any()) } returns Unit

        val engine = SyncEngine(cryptoService, deviceKeyStore, transport, identity, settingsRepository, storageManager)
        val item = ClipboardItem(
            id = "clip-image",
            type = ClipboardType.IMAGE,
            content = rawBase64,
            preview = "preview",
            metadata = mapOf("size" to "12"),
            deviceId = identity.deviceId,
            createdAt = Instant.parse("2024-03-21T12:30:45Z"),
            isPinned = false
        )

        engine.sendClipboard(item, "mac-device")

        val plaintextBytes = requireNotNull(capturedPlaintext)
        val decompressed = java.util.zip.GZIPInputStream(plaintextBytes.inputStream()).readBytes()
        val plaintext = decompressed.decodeToString()
        assertTrue(plaintext.contains("\"data_base64\":\"$rawBase64\""))
    }

    @Test
    fun `sendClipboard uses plain text mode when enabled`() = runTest {
        settingsRepository.setPlainTextModeEnabled(true)
        val engine = SyncEngine(mockk(), deviceKeyStore, transport, identity, settingsRepository, storageManager)
        
        val item = ClipboardItem(
            id = "plain",
            type = ClipboardType.TEXT,
            content = "Plain Hello",
            preview = "Plain Hello",
            metadata = emptyMap(),
            deviceId = identity.deviceId,
            createdAt = Instant.now(),
            isPinned = false
        )
        
        val envelope = engine.sendClipboard(item, "mac-device")
        
        assertEquals("", envelope.payload.encryption?.nonce)
        assertEquals("", envelope.payload.encryption?.tag)
        
        // Decode should also work in plain text mode
        val decoded = engine.decode(envelope)
        assertEquals("Plain Hello", Base64.getDecoder().decode(decoded.dataBase64).decodeToString())
    }

    @Test
    fun `decode throws for corrupted gzip data`() = runTest {
        val cryptoService = mockk<CryptoService>()
        val key = ByteArray(32) { 1 }
        coEvery { deviceKeyStore.loadKey(any()) } returns key
        
        // Return non-gzip data from decrypt
        coEvery { cryptoService.decrypt(any(), any(), any()) } returns "not-gzip".encodeToByteArray()
        
        val envelope = SyncEnvelope(
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = ClipboardType.TEXT,
                ciphertext = Base64.getEncoder().encodeToString("cipher".encodeToByteArray()),
                deviceId = "sender",
                encryption = EncryptionMetadata(
                    nonce = Base64.getEncoder().encodeToString(ByteArray(12)),
                    tag = Base64.getEncoder().encodeToString(ByteArray(16))
                )
            )
        )
        
        val engine = SyncEngine(cryptoService, deviceKeyStore, transport, identity, settingsRepository, storageManager)
        
        assertFailsWith<java.util.zip.ZipException> {
            engine.decode(envelope)
        }
    }

    private fun gzip(data: ByteArray): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        java.util.zip.GZIPOutputStream(output).use { it.write(data) }
        return output.toByteArray()
    }
}
