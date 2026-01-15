package com.hypo.clipboard.sync

import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardType
import androidx.test.core.app.ApplicationProvider
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SyncCoordinatorTest {
    private val repository = mockk<ClipboardRepository>(relaxed = true)
    private val syncEngine = mockk<SyncEngine>(relaxed = true)
    private val identity = mockk<DeviceIdentity> {
        every { deviceId } returns "android-device-123"
        every { deviceName } returns "Pixel"
    }
    private val transportManager = mockk<com.hypo.clipboard.transport.TransportManager>(relaxed = true) {
        every { peers } returns MutableStateFlow(emptyList())
    }
    private val deviceKeyStore = mockk<DeviceKeyStore>(relaxed = true) {
        coEvery { getAllDeviceIds() } returns listOf("mac-device")
    }
    private val lanTransportClient = mockk<com.hypo.clipboard.transport.ws.WebSocketTransportClient>(relaxed = true)
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    @Test
    fun upsertsClipboardEventsIntoRepository() = runTest {
        coEvery { repository.upsert(any()) } just Runs
        coEvery { repository.getLatestEntry() } returns null
        coEvery { repository.findMatchingEntryInHistory(any()) } returns null
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("mac-device")
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
        val coordinator = SyncCoordinator(
            repository = repository,
            syncEngine = syncEngine,
            identity = identity,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            context = context
        )
        coordinator.setTargetDevices(setOf("mac-device"))
        coordinator.start(this)

        val timestamp = Instant.parse("2024-03-21T12:30:45Z")
        val event = ClipboardEvent(
            id = "event-1",
            type = ClipboardType.TEXT,
            content = "Hello",
            preview = "Hello",
            metadata = emptyMap(),
            createdAt = timestamp,
            skipBroadcast = true
        )

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

        coVerify(exactly = 0) { syncEngine.sendClipboard(any(), any()) }

        coordinator.stop()
        advanceUntilIdle()
        clearMocks(repository)
        clearMocks(syncEngine)
    }

    @Test
    fun `broadcasts to targets when skipBroadcast is false`() = runTest {
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("mac-device")
        val coordinator = SyncCoordinator(repository, syncEngine, identity, transportManager, deviceKeyStore, lanTransportClient, context)
        
        // Wait for initial load
        advanceUntilIdle()
        
        coordinator.start(this)
        
        val event = ClipboardEvent(
            id = "event-3",
            type = ClipboardType.TEXT,
            content = "Broadcast me",
            preview = "Broadcast",
            metadata = emptyMap(),
            createdAt = Instant.now(),
            skipBroadcast = false
        )
        
        coordinator.onClipboardEvent(event)
        advanceUntilIdle()
        
        coVerify(atLeast = 1) { syncEngine.sendClipboard(any(), "mac-device") }
        
        coordinator.stop()
    }

    @Test
    fun `does not broadcast received items`() = runTest {
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("mac-device")
        val coordinator = SyncCoordinator(repository, syncEngine, identity, transportManager, deviceKeyStore, lanTransportClient, context)
        advanceUntilIdle()
        coordinator.start(this)
        
        val remoteEvent = ClipboardEvent(
            id = "remote-1",
            type = ClipboardType.TEXT,
            content = "From Mac",
            preview = "From Mac",
            metadata = emptyMap(),
            createdAt = Instant.now(),
            deviceId = "mac-device",
            skipBroadcast = true // Received items have this set to true
        )
        
        coordinator.onClipboardEvent(remoteEvent)
        advanceUntilIdle()
        
        // Verify upserted
        coVerify(exactly = 1) { repository.upsert(any()) }
        // Verify NOT broadcasted
        coVerify(exactly = 0) { syncEngine.sendClipboard(any(), any()) }
        
        coordinator.stop()
    }

    @Test
    fun startIsIdempotent() = runTest {
        coEvery { repository.upsert(any()) } just Runs
        coEvery { repository.getLatestEntry() } returns null
        coEvery { repository.findMatchingEntryInHistory(any()) } returns null
        coEvery { deviceKeyStore.getAllDeviceIds() } returns emptyList()
        val coordinator = SyncCoordinator(
            repository = repository,
            syncEngine = syncEngine,
            identity = identity,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            context = context
        )
        coordinator.start(this)
        coordinator.start(this)

        val event = ClipboardEvent(
            id = "event-2",
            type = ClipboardType.TEXT,
            content = "World",
            preview = "World",
            metadata = emptyMap(),
            createdAt = Instant.parse("2024-03-22T08:00:00Z"),
            skipBroadcast = true
        )
        coordinator.onClipboardEvent(event)
        advanceUntilIdle()

        coVerify(exactly = 1) { repository.upsert(any()) }
        coVerify(exactly = 0) { syncEngine.sendClipboard(any(), any()) }

        coordinator.stop()
        advanceUntilIdle()
    }

    @Test
    fun `recomputes targets and filters unpaired devices`() = runTest {
        val peersFlow = MutableStateFlow(emptyList<com.hypo.clipboard.transport.lan.DiscoveredPeer>())
        every { transportManager.peers } returns peersFlow
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("paired-device")
        
        val coordinator = SyncCoordinator(repository, syncEngine, identity, transportManager, deviceKeyStore, lanTransportClient, context)
        
        // Initially only paired device is target
        awaitTargets(coordinator, setOf("paired-device"))
        
        // Discovered unpaired device - should NOT be in targets
        peersFlow.value = listOf(mockPeer("unpaired-device"))
        // Wait a bit to ensure collect processes it
        delay(100)
        assertEquals(setOf("paired-device"), coordinator.targets.value)
        
        // Discovered paired device - should be in targets (already was because it's paired)
        peersFlow.value = listOf(mockPeer("paired-device"))
        delay(100)
        assertEquals(setOf("paired-device"), coordinator.targets.value)
        
        // Add manual target that is paired
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("paired-device", "paired-device-2")
        coordinator.addTargetDevice("paired-device-2")
        awaitTargets(coordinator, setOf("paired-device", "paired-device-2"))
        
        coordinator.stop()
    }

    private suspend fun awaitTargets(coordinator: SyncCoordinator, expected: Set<String>) {
        repeat(50) {
            if (coordinator.targets.value == expected) return
            delay(50)
        }
        assertEquals(expected, coordinator.targets.value, "Targets did not reach expected state")
    }

    private fun mockPeer(deviceId: String) = com.hypo.clipboard.transport.lan.DiscoveredPeer(
        serviceName = "service-$deviceId",
        host = "1.2.3.4",
        port = 1234,
        fingerprint = "fp",
        attributes = mapOf("device_id" to deviceId),
        lastSeen = Instant.now()
    )
}
