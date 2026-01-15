package com.hypo.clipboard.sync

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.domain.model.TransportOrigin
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import java.time.Instant
import java.util.Base64
import java.util.UUID
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class IncomingClipboardHandlerTest {
    private val testDispatcher = kotlinx.coroutines.test.UnconfinedTestDispatcher()
    private val syncEngine = mockk<SyncEngine>(relaxed = true)
    private val syncCoordinator = mockk<SyncCoordinator>(relaxed = true)
    private val identity = mockk<DeviceIdentity> {
        every { deviceId } returns "local-device"
    }
    private val accessibilityServiceChecker = mockk<com.hypo.clipboard.util.AccessibilityServiceChecker>(relaxed = true)
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val storageManager = mockk<com.hypo.clipboard.data.local.StorageManager>(relaxed = true)

    private lateinit var handler: IncomingClipboardHandler

    @BeforeTest
    fun setUp() {
        handler = IncomingClipboardHandler(
            syncEngine = syncEngine,
            syncCoordinator = syncCoordinator,
            identity = identity,
            accessibilityServiceChecker = accessibilityServiceChecker,
            context = context,
            storageManager = storageManager
        )
        handler.setDispatcher(testDispatcher)
    }

    @Test
    fun `processes valid text clipboard envelope`() = runTest {
        val senderId = "sender-device"
        val text = "Hello from remote"
        val textBase64 = Base64.getEncoder().encodeToString(text.toByteArray())
        
        val envelope = createEnvelope(senderId, textBase64, ClipboardType.TEXT)
        val payload = ClipboardPayload(ClipboardType.TEXT, textBase64, emptyMap())
        
        coEvery { syncEngine.decode(envelope) } returns payload
        
        handler.handle(envelope, TransportOrigin.LAN)
        advanceUntilIdle()
        
        coVerify(exactly = 1) { 
            syncCoordinator.onClipboardEvent(withArg { event ->
                assertEquals(ClipboardType.TEXT, event.type)
                assertEquals(text, event.content)
                assertEquals(senderId.lowercase(), event.deviceId)
                assertEquals(TransportOrigin.LAN, event.transportOrigin)
            })
        }
    }

    @Test
    fun `deduplicates message by id`() = runTest {
        val dataBase64 = Base64.getEncoder().encodeToString("data".toByteArray())
        val envelope = createEnvelope("sender", dataBase64, ClipboardType.TEXT)
        coEvery { syncEngine.decode(any()) } returns ClipboardPayload(ClipboardType.TEXT, dataBase64, emptyMap())
        
        handler.handle(envelope)
        // Wait for coroutine to cache it
        advanceUntilIdle()
        
        handler.handle(envelope) // Duplicate ID
        advanceUntilIdle()
        
        coVerify(exactly = 1) { syncEngine.decode(any()) }
        coVerify(exactly = 2) { syncCoordinator.onClipboardEvent(any()) } // Second call uses cache to move to top
    }

    @Test
    fun `deduplicates message by nonce`() = runTest {
        val nonce = Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12))
        val dataBase64 = Base64.getEncoder().encodeToString("data1".toByteArray())
        val env1 = createEnvelope("sender", dataBase64, ClipboardType.TEXT, nonce = nonce, id = "id-1")
        val env2 = createEnvelope("sender", dataBase64, ClipboardType.TEXT, nonce = nonce, id = "id-2")
        
        coEvery { syncEngine.decode(any()) } returns ClipboardPayload(ClipboardType.TEXT, dataBase64, emptyMap())
        
        handler.handle(env1)
        handler.handle(env2) // Duplicate nonce
        advanceUntilIdle()
        
        coVerify(exactly = 1) { syncEngine.decode(any()) }
        coVerify(exactly = 1) { syncCoordinator.onClipboardEvent(any()) }
    }

    @Test
    fun `skips messages from own device`() = runTest {
        val envelope = createEnvelope("local-device", "data", ClipboardType.TEXT)
        
        handler.handle(envelope)
        advanceUntilIdle()
        
        coVerify(exactly = 0) { syncEngine.decode(any()) }
        coVerify(exactly = 0) { syncCoordinator.onClipboardEvent(any()) }
    }

    @Test
    fun `processes image and saves to storage`() = runTest {
        val imgData = byteArrayOf(1, 2, 3, 4)
        val imgBase64 = Base64.getEncoder().encodeToString(imgData)
        val envelope = createEnvelope("sender", imgBase64, ClipboardType.IMAGE)
        val payload = ClipboardPayload(ClipboardType.IMAGE, imgBase64, mapOf("format" to "png"))
        
        coEvery { syncEngine.decode(envelope) } returns payload
        every { storageManager.save(any<ByteArray>(), any<String>(), any<Boolean>()) } returns "/cache/image.png"
        
        handler.handle(envelope)
        advanceUntilIdle()
        
        coVerify(exactly = 1) { 
            syncCoordinator.onClipboardEvent(withArg { event ->
                assertEquals(ClipboardType.IMAGE, event.type)
                assertEquals("", event.content) // Content cleared for large items
                assertEquals("/cache/image.png", event.localPath)
            })
        }
    }

    private fun createEnvelope(
        senderId: String, 
        ciphertext: String, 
        type: ClipboardType,
        nonce: String = "nonce-${UUID.randomUUID()}",
        id: String = UUID.randomUUID().toString()
    ) = SyncEnvelope(
        id = id,
        type = MessageType.CLIPBOARD,
        payload = Payload(
            deviceId = senderId,
            deviceName = "Remote Device",
            ciphertext = ciphertext,
            contentType = type,
            encryption = EncryptionMetadata(
                nonce = nonce,
                tag = "tag"
            )
        )
    )
}
