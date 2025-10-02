package com.hypo.clipboard.sync

import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardType
import io.mockk.Runs
import io.mockk.clearMocks
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.just
import io.mockk.mockk
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SyncCoordinatorTest {
    private val repository = mockk<ClipboardRepository>(relaxed = true)
    private val syncEngine = mockk<SyncEngine>(relaxed = true)
    private val identity = mockk<DeviceIdentity> {
        every { deviceId } returns "android-device-123"
    }
    private val coordinator = SyncCoordinator(repository, syncEngine, identity)

    @Test
    fun upsertsClipboardEventsIntoRepository() = runTest {
        coEvery { repository.upsert(any()) } just Runs
        coEvery { syncEngine.sendClipboard(any(), any()) } answers {
            SyncEnvelope(
                type = MessageType.CLIPBOARD,
                payload = Payload(
                    contentType = ClipboardType.TEXT,
                    ciphertext = "",
                    deviceId = identity.deviceId,
                    encryption = EncryptionMetadata(nonce = "", tag = "")
                )
            )
        }
        coordinator.setTargetDevices(setOf("mac-device"))
        coordinator.start(this)

        val timestamp = Instant.parse("2024-03-21T12:30:45Z")
        val event = ClipboardEvent(id = "event-1", text = "Hello", createdAt = timestamp)

        coordinator.onClipboardEvent(event)
        advanceUntilIdle()

        coVerify(exactly = 1) {
            repository.upsert(withArg { item ->
                assertEquals("event-1", item.id)
                assertEquals(ClipboardType.TEXT, item.type)
                assertEquals("Hello", item.content)
                assertEquals("Hello", item.preview)
                assertEquals("android-device-123", item.deviceId)
                assertEquals(timestamp, item.createdAt)
                assertFalse(item.isPinned)
            })
        }

        coVerify(exactly = 1) { syncEngine.sendClipboard(any(), "mac-device") }

        coordinator.stop()
        clearMocks(repository)
        clearMocks(syncEngine)
    }

    @Test
    fun startIsIdempotent() = runTest {
        coEvery { repository.upsert(any()) } just Runs
        coordinator.start(this)
        coordinator.start(this)

        val event = ClipboardEvent(id = "event-2", text = "World", createdAt = Instant.parse("2024-03-22T08:00:00Z"))
        coordinator.onClipboardEvent(event)
        advanceUntilIdle()

        coVerify(exactly = 1) { repository.upsert(any()) }
        coVerify(exactly = 0) { syncEngine.sendClipboard(any(), any()) }

        coordinator.stop()
        clearMocks(repository)
        clearMocks(syncEngine)
    }
}
