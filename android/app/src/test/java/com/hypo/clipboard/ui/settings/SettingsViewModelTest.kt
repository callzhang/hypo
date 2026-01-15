package com.hypo.clipboard.ui.settings

import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.fakes.FakeSettingsRepository
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SettingsViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val settingsRepository = FakeSettingsRepository()
    private val peersFlow = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    private val transportFlow = MutableStateFlow<Map<String, com.hypo.clipboard.transport.ActiveTransport>>(emptyMap())
    private val cloudConnectionState = MutableStateFlow(com.hypo.clipboard.transport.ConnectionState.Disconnected)
    private lateinit var transportManager: TransportManager
    private val deviceKeyStore = mockk<com.hypo.clipboard.sync.DeviceKeyStore>(relaxed = true) {
        coEvery { getAllDeviceIds() } returns emptyList()
    }
    private val lanTransportClient = mockk<com.hypo.clipboard.transport.ws.WebSocketTransportClient>(relaxed = true)
    private val syncCoordinator = mockk<com.hypo.clipboard.sync.SyncCoordinator>(relaxed = true)
    private val connectionStatusProber = mockk<com.hypo.clipboard.transport.ConnectionStatusProber>(relaxed = true) {
        every { deviceDualStatus } returns MutableStateFlow(emptyMap())
    }
    private val accessibilityServiceChecker = mockk<com.hypo.clipboard.util.AccessibilityServiceChecker>(relaxed = true)
    private val context = androidx.test.core.app.ApplicationProvider.getApplicationContext<android.content.Context>()

    @BeforeTest
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        transportManager = mockk(relaxed = true)
        every { transportManager.peers } returns peersFlow
        every { transportManager.lastSuccessfulTransport } returns transportFlow
        every { transportManager.cloudConnectionState } returns cloudConnectionState
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `state combines settings and discovered peers`() = runTest {
        settingsRepository.emit(
            UserSettings(
                lanSyncEnabled = false,
                cloudSyncEnabled = false,
                historyLimit = 120,
                plainTextModeEnabled = true
            )
        )

        val viewModel = SettingsViewModel(
            settingsRepository = settingsRepository,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            syncCoordinator = syncCoordinator,
            connectionStatusProber = connectionStatusProber,
            accessibilityServiceChecker = accessibilityServiceChecker,
            context = context
        )
        runCurrent()

        val state = viewModel.state.value
        assertEquals(false, state.lanSyncEnabled)
        assertEquals(120, state.historyLimit)
        assertEquals(true, state.plainTextModeEnabled)
        assertEquals(emptyList<DiscoveredPeer>(), state.discoveredPeers)
        viewModel.viewModelScope.cancel()
    }

    @Test
    fun `callbacks delegate to repository`() = runTest {
        val viewModel = SettingsViewModel(
            settingsRepository = settingsRepository,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            syncCoordinator = syncCoordinator,
            connectionStatusProber = connectionStatusProber,
            accessibilityServiceChecker = accessibilityServiceChecker,
            context = context
        )
        runCurrent()

        viewModel.onLanSyncChanged(false)
        viewModel.onHistoryLimitChanged(150)
        viewModel.onPlainTextModeChanged(true)
        runCurrent()

        assertEquals(listOf(false), settingsRepository.lanSyncCalls)
        assertEquals(listOf(150), settingsRepository.historyLimitCalls)
        assertEquals(listOf(true), settingsRepository.plainTextCalls)
        viewModel.viewModelScope.cancel()
    }
    
    @Test
    fun `removeDevice clears all related state`() = runTest {
        val viewModel = SettingsViewModel(
            settingsRepository = settingsRepository,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            syncCoordinator = syncCoordinator,
            connectionStatusProber = connectionStatusProber,
            accessibilityServiceChecker = accessibilityServiceChecker,
            context = context
        )
        
        val peer = DiscoveredPeer(
            serviceName = "TestDevice",
            host = "1.1.1.1",
            port = 1234,
            fingerprint = null,
            attributes = mapOf("device_id" to "device-123"),
            lastSeen = java.time.Instant.now()
        )
        
        viewModel.removeDevice(peer)
        runCurrent()
        
        coVerify { transportManager.removePeer("TestDevice") }
        coVerify { deviceKeyStore.deleteKey("device-123") }
        coVerify { transportManager.forgetPairedDevice("device-123") }
        coVerify { syncCoordinator.removeTargetDevice("device-123") }
        
        viewModel.viewModelScope.cancel()
    }
    
    @Test
    fun `checkPeerStatus triggers probe`() = runTest {
        val viewModel = SettingsViewModel(
            settingsRepository = settingsRepository,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            syncCoordinator = syncCoordinator,
            connectionStatusProber = connectionStatusProber,
            accessibilityServiceChecker = accessibilityServiceChecker,
            context = context
        )
        
        viewModel.checkPeerStatus()
        
        verify { connectionStatusProber.probeNow() }
        viewModel.viewModelScope.cancel()
    }
    
    @Test
    fun `state includes paired devices from storage`() = runTest {
        // Setup paired device in storage
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("device-123")
        every { transportManager.getDeviceName("device-123") } returns "Test Paired Device"
        
        val viewModel = SettingsViewModel(
            settingsRepository = settingsRepository,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            syncCoordinator = syncCoordinator,
            connectionStatusProber = connectionStatusProber,
            accessibilityServiceChecker = accessibilityServiceChecker,
            context = context
        )
        runCurrent()
        
        val state = viewModel.state.value
        assertEquals(1, state.discoveredPeers.size)
        val uiPeer = state.discoveredPeers[0]
        assertEquals("Test Paired Device", uiPeer.serviceName)
        assertEquals("device-123", uiPeer.attributes["device_id"])
        
        viewModel.viewModelScope.cancel()
    }
    
    @Test
    fun `orphaned keys are cleaned up`() = runTest {
        // Setup orphaned key (exists in keystore but no name in transport manager)
        coEvery { deviceKeyStore.getAllDeviceIds() } returns listOf("orphaned-device")
        every { transportManager.getDeviceName("orphaned-device") } returns null
        
        val viewModel = SettingsViewModel(
            settingsRepository = settingsRepository,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            syncCoordinator = syncCoordinator,
            connectionStatusProber = connectionStatusProber,
            accessibilityServiceChecker = accessibilityServiceChecker,
            context = context
        )
        runCurrent()
        
        // Should trigger deleteKey
        coVerify { deviceKeyStore.deleteKey("orphaned-device") }
        coVerify { transportManager.forgetPairedDevice("orphaned-device") }
        
        // ui state should be empty
        assertTrue(viewModel.state.value.discoveredPeers.isEmpty())
        
        viewModel.viewModelScope.cancel()
    }
}
