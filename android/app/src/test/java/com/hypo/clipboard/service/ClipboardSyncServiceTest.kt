package com.hypo.clipboard.service

import android.content.Context
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.data.local.StorageManager
import com.hypo.clipboard.pairing.PairingHandshakeManager
import com.hypo.clipboard.sync.ClipboardAccessChecker
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.IncomingClipboardHandler
import com.hypo.clipboard.sync.SyncCoordinator
import com.hypo.clipboard.transport.ConnectionStatusProber
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.ws.RelayWebSocketClient
import com.hypo.clipboard.transport.ws.WebSocketTransportClient
import com.hypo.clipboard.util.AccessibilityServiceChecker
import io.mockk.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClipboardSyncServiceTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val testDispatcher = UnconfinedTestDispatcher()
    private lateinit var service: ClipboardSyncService

    // Mocks
    private val syncCoordinator = mockk<SyncCoordinator>(relaxed = true)
    private val transportManager = mockk<TransportManager>(relaxed = true)
    private val deviceIdentity = mockk<DeviceIdentity>(relaxed = true)
    private val repository = mockk<ClipboardRepository>(relaxed = true)
    private val incomingClipboardHandler = mockk<IncomingClipboardHandler>(relaxed = true)
    private val lanTransportClient = mockk<WebSocketTransportClient>(relaxed = true)
    private val relayWebSocketClient = mockk<RelayWebSocketClient>(relaxed = true)
    private val clipboardAccessChecker = mockk<ClipboardAccessChecker>(relaxed = true)
    private val connectionStatusProber = mockk<ConnectionStatusProber>(relaxed = true)
    private val pairingHandshakeManager = mockk<PairingHandshakeManager>(relaxed = true)
    private val storageManager = mockk<StorageManager>(relaxed = true)
    private val accessibilityServiceChecker = mockk<AccessibilityServiceChecker>(relaxed = true)

    @Before
    fun setUp() {
        Dispatchers.setMain(testDispatcher)
        mockkStatic(android.util.Log::class)
        every { android.util.Log.d(any(), any()) } returns 0
        every { android.util.Log.i(any(), any()) } returns 0
        every { android.util.Log.w(any<String>(), any<String>()) } returns 0
        every { android.util.Log.w(any<String>(), any<String>(), any<Throwable>()) } returns 0
        every { android.util.Log.e(any<String>(), any<String>()) } returns 0
        every { android.util.Log.e(any<String>(), any<String>(), any<Throwable>()) } returns 0

        // Mock StateFlows and Flow returns
        every { transportManager.isAdvertising } returns MutableStateFlow(false)
        every { transportManager.cloudConnectionState } returns MutableStateFlow(com.hypo.clipboard.transport.ConnectionState.Disconnected)
        every { connectionStatusProber.deviceDualStatus } returns MutableStateFlow(emptyMap())
        every { repository.observeHistory(any()) } returns MutableStateFlow(emptyList())

        val controller = Robolectric.buildService(ClipboardSyncService::class.java)
        service = controller.get()
        
        // Manual injection BEFORE component initialization
        injectMocks(service)
        
        // Trigger initialization manually so it uses our mocks
        service.startSyncComponents()
        
        // call onCreate to satisfy service lifecycle (it will skip startSyncComponents due to isInitialized flag)
        controller.create()
        
        // RE-INJECT after super.onCreate() overwrote them (if it was a Hilt-managed instance)
        injectMocks(service)
    }

    private fun injectMocks(service: ClipboardSyncService) {
        val fields = mapOf(
            "syncCoordinator" to syncCoordinator,
            "transportManager" to transportManager,
            "deviceIdentity" to deviceIdentity,
            "repository" to repository,
            "incomingClipboardHandler" to incomingClipboardHandler,
            "lanTransportClient" to lanTransportClient,
            "relayWebSocketClient" to relayWebSocketClient,
            "clipboardAccessChecker" to clipboardAccessChecker,
            "connectionStatusProber" to connectionStatusProber,
            "pairingHandshakeManager" to pairingHandshakeManager,
            "storageManager" to storageManager,
            "accessibilityServiceChecker" to accessibilityServiceChecker
        )
        
        fields.forEach { (name, mock) ->
            val field = service.javaClass.getDeclaredField(name)
            field.isAccessible = true
            field.set(service, mock)
        }
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        unmockkStatic(android.util.Log::class)
    }

    @Test
    fun `service starts correctly and initializes components`() {
        verify { syncCoordinator.start(any()) }
        verify { transportManager.start(any()) }
        verify { relayWebSocketClient.startReceiving() }
        verify { connectionStatusProber.start() }
    }
    
    @Test
    fun `service shutdown stops components`() {
        service.onDestroy()
        
        verify { transportManager.stop() }
        verify { syncCoordinator.stop() }
        verify { connectionStatusProber.cleanup() }
    }
}
