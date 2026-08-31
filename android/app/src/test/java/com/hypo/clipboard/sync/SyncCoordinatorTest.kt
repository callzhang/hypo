package com.hypo.clipboard.sync

import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
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
    fun `does not rebuild latest item for repeated remote content`() = runTest {
        val latest = ClipboardItem(
            id = "existing",
            type = ClipboardType.TEXT,
            content = "From Mac",
            preview = "From Mac",
            metadata = emptyMap(),
            deviceId = "mac-device",
            deviceName = "Mac",
            createdAt = Instant.parse("2024-03-21T12:30:45Z"),
            isPinned = false,
            isEncrypted = true,
            transportOrigin = com.hypo.clipboard.domain.model.TransportOrigin.LAN
        )
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("mac-device")
        coEvery { repository.getLatestEntry() } returns latest
        coEvery { repository.findMatchingEntryInHistory(any()) } returns null

        val coordinator = SyncCoordinator(repository, syncEngine, identity, transportManager, deviceKeyStore, lanTransportClient, context)
        advanceUntilIdle()
        coordinator.start(this)

        coordinator.onClipboardEvent(
            ClipboardEvent(
                id = "remote-repeat",
                type = ClipboardType.TEXT,
                content = "From Mac",
                preview = "From Mac",
                metadata = emptyMap(),
                createdAt = Instant.now(),
                deviceId = "mac-device",
                deviceName = "Mac",
                skipBroadcast = true,
                isEncrypted = true,
                transportOrigin = com.hypo.clipboard.domain.model.TransportOrigin.CLOUD
            )
        )
        advanceUntilIdle()

        coVerify(exactly = 0) { repository.delete(any()) }
        coVerify(exactly = 0) { repository.upsert(any()) }
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
        assertTargetsRemain(coordinator, setOf("paired-device"))
        
        // Discovered paired device - should be in targets (already was because it's paired)
        peersFlow.value = listOf(mockPeer("paired-device"))
        assertTargetsRemain(coordinator, setOf("paired-device"))
        
        // Add manual target that is paired
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("paired-device", "paired-device-2")
        coordinator.addTargetDevice("paired-device-2")
        awaitTargets(coordinator, setOf("paired-device", "paired-device-2"))
        
        coordinator.stop()
    }

    /**
     * Waits, in *real* time, for [coordinator]'s targets to settle on [expected].
     *
     * The real time is the whole point. `runTest` runs on a virtual scheduler
     * where `delay` returns immediately, so a polling loop written inside it
     * spins through every iteration instantly and asserts against whatever
     * happened to be there. An earlier attempt at fixing this flake raised the
     * iteration count from 50 to 200 and changed nothing at all, because the
     * loop never waited in the first place.
     *
     * What it is waiting for is genuinely off the test scheduler:
     * SyncCoordinator refreshes its paired-device cache on `Dispatchers.Default`,
     * which is real threads and real time.
     */
    private suspend fun awaitTargets(coordinator: SyncCoordinator, expected: Set<String>) {
        withContext(Dispatchers.Default) {
            withTimeoutOrNull(10_000) {
                while (coordinator.targets.value != expected) {
                    delay(25)
                }
            }
        }

        assertEquals(expected, coordinator.targets.value, "Targets did not reach expected state")
    }

    /**
     * Asserts targets *stay* [expected] rather than merely reaching it, for the
     * cases where the point is that something was filtered out and must not
     * appear. A bare delay-then-assert would pass for the wrong reason if the
     * unwanted value simply had not arrived yet -- and on the virtual scheduler
     * it would not even wait.
     */
    private suspend fun assertTargetsRemain(coordinator: SyncCoordinator, expected: Set<String>) {
        withContext(Dispatchers.Default) {
            repeat(10) {
                assertEquals(expected, coordinator.targets.value)
                delay(30)
            }
        }
    }

    private fun mockPeer(deviceId: String) = com.hypo.clipboard.transport.lan.DiscoveredPeer(
        serviceName = "service-$deviceId",
        host = "1.2.3.4",
        port = 1234,
        fingerprint = "fp",
        attributes = mapOf("device_id" to deviceId),
        lastSeen = Instant.now()
    )

    /**
     * One user action produces two events with different ids: ProcessTextActivity
     * fires FORCE_PROCESS with the text, finishes, and MainActivity's onResume
     * fires it again without the text, which falls back to reading the clipboard.
     * The peer cannot dedup them -- the ids differ -- so they must not both be
     * sent.
     */
    @Test
    fun `does not broadcast the same content twice in quick succession`() = runTest {
        coEvery { repository.getLatestEntry() } returns null
        coEvery { repository.findMatchingEntryInHistory(any()) } returns null
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("mac-device")

        val coordinator = SyncCoordinator(
            repository, syncEngine, identity, transportManager, deviceKeyStore, lanTransportClient, context)
        val clock = MutableClock(Instant.parse("2026-08-29T20:00:00Z"))
        coordinator.clock = clock

        advanceUntilIdle()
        coordinator.setTargetDevices(setOf("mac-device"))
        coordinator.start(this)

        coordinator.onClipboardEvent(textEvent("event-a", "one copy"))
        advanceUntilIdle()

        // The real pair arrives about 40ms apart.
        clock.advanceMillis(40)
        coordinator.onClipboardEvent(textEvent("event-b", "one copy"))
        advanceUntilIdle()

        coVerify(exactly = 1) { syncEngine.sendClipboard(any(), "mac-device") }

        coordinator.stop()
        advanceUntilIdle()
        clearMocks(syncEngine)
    }

    /**
     * The behaviour the existing comment protects: "Broadcast even if item matched
     * history - user may have re-copied it". A person copying the same string again
     * later is a real second event, and suppressing it would be a worse bug than
     * the one being fixed.
     */
    @Test
    fun `broadcasts the same content again after the window`() = runTest {
        coEvery { repository.getLatestEntry() } returns null
        coEvery { repository.findMatchingEntryInHistory(any()) } returns null
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("mac-device")

        val coordinator = SyncCoordinator(
            repository, syncEngine, identity, transportManager, deviceKeyStore, lanTransportClient, context)
        val clock = MutableClock(Instant.parse("2026-08-29T20:00:00Z"))
        coordinator.clock = clock

        advanceUntilIdle()
        coordinator.setTargetDevices(setOf("mac-device"))
        coordinator.start(this)

        coordinator.onClipboardEvent(textEvent("event-a", "copied twice on purpose"))
        advanceUntilIdle()

        clock.advanceMillis(SyncCoordinator.BROADCAST_DEDUP_WINDOW.toMillis() + 1_000)
        coordinator.onClipboardEvent(textEvent("event-b", "copied twice on purpose"))
        advanceUntilIdle()

        coVerify(exactly = 2) { syncEngine.sendClipboard(any(), "mac-device") }

        coordinator.stop()
        advanceUntilIdle()
        clearMocks(syncEngine)
    }

    @Test
    fun `different content inside the window is still broadcast`() = runTest {
        coEvery { repository.getLatestEntry() } returns null
        coEvery { repository.findMatchingEntryInHistory(any()) } returns null
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("mac-device")

        val coordinator = SyncCoordinator(
            repository, syncEngine, identity, transportManager, deviceKeyStore, lanTransportClient, context)
        val clock = MutableClock(Instant.parse("2026-08-29T20:00:00Z"))
        coordinator.clock = clock

        advanceUntilIdle()
        coordinator.setTargetDevices(setOf("mac-device"))
        coordinator.start(this)

        coordinator.onClipboardEvent(textEvent("event-a", "first thing"))
        advanceUntilIdle()
        clock.advanceMillis(40)
        coordinator.onClipboardEvent(textEvent("event-b", "second thing"))
        advanceUntilIdle()

        coVerify(exactly = 2) { syncEngine.sendClipboard(any(), "mac-device") }

        coordinator.stop()
        advanceUntilIdle()
        clearMocks(syncEngine)
    }

    /**
     * A suppressed repeat must not refresh the window, or a source retrying in a
     * tight loop would hold it open indefinitely and the content would never sync.
     */
    @Test
    fun `a repeating source cannot hold the window open forever`() = runTest {
        coEvery { repository.getLatestEntry() } returns null
        coEvery { repository.findMatchingEntryInHistory(any()) } returns null
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("mac-device")

        val coordinator = SyncCoordinator(
            repository, syncEngine, identity, transportManager, deviceKeyStore, lanTransportClient, context)
        val clock = MutableClock(Instant.parse("2026-08-29T20:00:00Z"))
        coordinator.clock = clock

        advanceUntilIdle()
        coordinator.setTargetDevices(setOf("mac-device"))
        coordinator.start(this)

        coordinator.onClipboardEvent(textEvent("event-0", "retried"))
        advanceUntilIdle()

        repeat(5) { attempt ->
            clock.advanceMillis(500)
            coordinator.onClipboardEvent(textEvent("event-$attempt-retry", "retried"))
            advanceUntilIdle()
        }

        // 2.5s of retries have passed the 2s window, so one of them got through.
        coVerify(atLeast = 2) { syncEngine.sendClipboard(any(), "mac-device") }

        coordinator.stop()
        advanceUntilIdle()
        clearMocks(syncEngine)
    }

    private fun textEvent(id: String, content: String) = ClipboardEvent(
        id = id,
        type = ClipboardType.TEXT,
        content = content,
        preview = content,
        metadata = emptyMap(),
        createdAt = Instant.parse("2026-08-29T20:00:00Z")
    )

    /** A clock the test moves by hand; the dedup window is wall-clock, not virtual time. */
    private class MutableClock(private var instant: Instant) : java.time.Clock() {
        override fun getZone(): java.time.ZoneId = java.time.ZoneOffset.UTC
        override fun withZone(zone: java.time.ZoneId): java.time.Clock = this
        override fun instant(): Instant = instant
        fun advanceMillis(millis: Long) {
            instant = instant.plusMillis(millis)
        }
    }

}
