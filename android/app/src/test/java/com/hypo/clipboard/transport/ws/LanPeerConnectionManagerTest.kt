package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.MessageType
import com.hypo.clipboard.sync.Payload
import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import io.mockk.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LanPeerConnectionManagerTest {

    private val transportManager = mockk<TransportManager>(relaxed = true)
    private val frameCodec = mockk<TransportFrameCodec>(relaxed = true)
    private val deviceIdentity = mockk<DeviceIdentity>(relaxed = true)
    private lateinit var manager: LanPeerConnectionManager

    @Before
    fun setUp() {
        mockkStatic(android.util.Log::class)
        every { android.util.Log.d(any(), any()) } returns 0
        every { android.util.Log.i(any(), any()) } returns 0
        every { android.util.Log.w(any<String>(), any<String>()) } returns 0
        every { android.util.Log.e(any<String>(), any<String>()) } returns 0
        every { android.util.Log.e(any<String>(), any<String>(), any<Throwable>()) } returns 0

        every { deviceIdentity.deviceId } returns "test-device-id"

        // Mock WebSocketTransportClient construction
        mockkConstructor(WebSocketTransportClient::class)
        every { anyConstructed<WebSocketTransportClient>().startReceiving() } just Runs
        coEvery { anyConstructed<WebSocketTransportClient>().disconnect() } just Runs
        // Fix ambiguity by using explicit type for matcher
        every { anyConstructed<WebSocketTransportClient>().setIncomingClipboardHandler(any<(SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit>()) } just Runs
        every { anyConstructed<WebSocketTransportClient>().setConnectionEventListener(any()) } just Runs
        every { anyConstructed<WebSocketTransportClient>().isConnected() } returns true // Default connected
        coEvery { anyConstructed<WebSocketTransportClient>().send(any()) } just Runs
        
        manager = LanPeerConnectionManager(
            transportManager = transportManager,
            frameCodec = frameCodec,
            deviceIdentity = deviceIdentity
        )
    }

    @After
    fun tearDown() {
        unmockkConstructor(WebSocketTransportClient::class)
        unmockkAll()
    }

    @Test
    fun `syncPeerConnections creates connections for new peers`() = runBlocking {
        val peer = DiscoveredPeer(
            serviceName = "TargetDevice",
            host = "192.168.1.100",
            port = 8080,
            fingerprint = null,
            attributes = mapOf("device_id" to "target-id"),
            lastSeen = java.time.Instant.now()
        )
        every { transportManager.currentPeers() } returns listOf(peer)
        
        manager.syncPeerConnections()
        
        // Verify startReceiving was called
        verify { anyConstructed<WebSocketTransportClient>().startReceiving() }
        
        val connections = manager.getAllConnections()
        assertTrue(connections.containsKey("target-id"))
    }

    @Test
    fun `syncPeerConnections removes stale connections`() = runBlocking {
        val peer = DiscoveredPeer(
            serviceName = "TargetDevice",
            host = "192.168.1.100",
            port = 8080,
            fingerprint = null,
            attributes = mapOf("device_id" to "target-id"),
            lastSeen = java.time.Instant.now()
        )
        every { transportManager.currentPeers() } returns listOf(peer)
        
        // Add peer
        manager.syncPeerConnections()
        
        // Remove peer
        every { transportManager.currentPeers() } returns emptyList()
        manager.syncPeerConnections()
        
        // Verify disconnect was called
        coVerify { anyConstructed<WebSocketTransportClient>().disconnect() }
        
        val connections = manager.getAllConnections()
        assertTrue(connections.isEmpty())
    }

    @Test
    fun `sendToPeer routes through connected client`() = runBlocking {
        val peer = DiscoveredPeer(
            serviceName = "TargetDevice",
            host = "192.168.1.100",
            port = 8080,
            fingerprint = null,
            attributes = mapOf("device_id" to "target-id"),
            lastSeen = java.time.Instant.now()
        )
        every { transportManager.currentPeers() } returns listOf(peer)
        coEvery { anyConstructed<WebSocketTransportClient>().send(any()) } just Runs
        
        manager.syncPeerConnections()
        
        val envelope = SyncEnvelope(type = MessageType.CLIPBOARD, payload = Payload())
        val result = manager.sendToPeer("target-id", envelope)
        
        assertTrue(result)
        coVerify { anyConstructed<WebSocketTransportClient>().send(envelope) }
    }
    
    @Test
    fun `sendToPeer fails if client not connected`() = runBlocking {
        // No peers discovered
        every { transportManager.currentPeers() } returns emptyList()
        manager.syncPeerConnections()
        
        val envelope = SyncEnvelope(type = MessageType.CLIPBOARD, payload = Payload())
        val result = manager.sendToPeer("target-id", envelope)
        
        // Should return false as no client exists
        assertEquals(false, result)
    }

    @Test
    fun `sendToPeer fails if send throws exception`() = runBlocking {
         val peer = DiscoveredPeer(
            serviceName = "TargetDevice",
            host = "192.168.1.100",
            port = 8080,
            fingerprint = null,
            attributes = mapOf("device_id" to "target-id"),
            lastSeen = java.time.Instant.now()
        )
        every { transportManager.currentPeers() } returns listOf(peer)
        
        manager.syncPeerConnections()
        
        // Mock exception
        coEvery { anyConstructed<WebSocketTransportClient>().send(any()) } throws RuntimeException("Network error")
        
        val envelope = SyncEnvelope(type = MessageType.CLIPBOARD, payload = Payload())
        val result = manager.sendToPeer("target-id", envelope)
        
        assertEquals(false, result)
    }

    @Test
    fun `closeAllConnections disconnects all peers`() = runBlocking {
        val peer = DiscoveredPeer(
            serviceName = "TargetDevice",
            host = "192.168.1.100",
            port = 8080,
            fingerprint = null,
            attributes = mapOf("device_id" to "target-id"),
            lastSeen = java.time.Instant.now()
        )
        every { transportManager.currentPeers() } returns listOf(peer)
        
        manager.syncPeerConnections()
        
        manager.closeAllConnections()
        
        coVerify { anyConstructed<WebSocketTransportClient>().disconnect() }
    }

    @Test
    fun `sendToAllPeers attempts to send to all connected peers`() = runBlocking {
        val peer1 = DiscoveredPeer("P1", "1.1.1.1", 1, null, mapOf("device_id" to "id1"), java.time.Instant.now())
        val peer2 = DiscoveredPeer("P2", "1.1.1.2", 2, null, mapOf("device_id" to "id2"), java.time.Instant.now())
        every { transportManager.currentPeers() } returns listOf(peer1, peer2)
        
        manager.syncPeerConnections()
        
        val envelope = SyncEnvelope(type = MessageType.CLIPBOARD, payload = Payload())
        val count = manager.sendToAllPeers(envelope)
        
        assertEquals(2, count)
        coVerify(exactly = 2) { anyConstructed<WebSocketTransportClient>().send(envelope) }
    }
    
    @Test
    fun `setIncomingClipboardHandler updates all clients`() = runBlocking {
        val peer = DiscoveredPeer("P1", "1.1.1.1", 1, null, mapOf("device_id" to "id1"), java.time.Instant.now())
        every { transportManager.currentPeers() } returns listOf(peer)
        manager.syncPeerConnections()
        
        val handler: (SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit = { _, _ -> }
        manager.setIncomingClipboardHandler(handler)
        
        verify { anyConstructed<WebSocketTransportClient>().setIncomingClipboardHandler(any<(SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit>()) }
    }
}
