package com.hypo.clipboard.ui.settings

import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.fakes.FakeSettingsRepository
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
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
    private val lanWebSocketClient = mockk<com.hypo.clipboard.transport.ws.WebSocketTransportClient>(relaxed = true)
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
            lanWebSocketClient = lanWebSocketClient,
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
            lanWebSocketClient = lanWebSocketClient,
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
}
