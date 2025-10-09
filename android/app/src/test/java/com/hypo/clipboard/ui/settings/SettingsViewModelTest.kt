package com.hypo.clipboard.ui.settings

import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.fakes.FakeSettingsRepository
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import io.mockk.every
import io.mockk.mockk
import java.time.Instant
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val settingsRepository = FakeSettingsRepository()
    private val peersFlow = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    private val transportManager: TransportManager = mockk(relaxed = true) {
        every { this@mockk.peers } returns peersFlow
    }

    @BeforeTest
    fun setUp() {
        setMain(dispatcher)
    }

    @AfterTest
    fun tearDown() {
        resetMain()
    }

    @Test
    fun `state combines settings and discovered peers`() = runTest {
        val peer = DiscoveredPeer(
            serviceName = "Hypo#1",
            host = "192.168.1.10",
            port = 8080,
            fingerprint = "abc",
            attributes = emptyMap(),
            lastSeen = Instant.parse("2024-01-01T00:00:00Z")
        )
        peersFlow.value = listOf(peer)
        settingsRepository.emit(
            UserSettings(
                lanSyncEnabled = false,
                cloudSyncEnabled = false,
                historyLimit = 120,
                autoDeleteDays = 7
            )
        )

        val viewModel = SettingsViewModel(settingsRepository, transportManager)
        runCurrent()

        val state = viewModel.state.value
        assertEquals(false, state.lanSyncEnabled)
        assertEquals(false, state.cloudSyncEnabled)
        assertEquals(120, state.historyLimit)
        assertEquals(7, state.autoDeleteDays)
        assertEquals(listOf(peer), state.discoveredPeers)
    }

    @Test
    fun `callbacks delegate to repository`() = runTest {
        val viewModel = SettingsViewModel(settingsRepository, transportManager)
        runCurrent()

        viewModel.onLanSyncChanged(false)
        viewModel.onCloudSyncChanged(false)
        viewModel.onHistoryLimitChanged(150)
        viewModel.onAutoDeleteDaysChanged(5)
        runCurrent()

        assertEquals(listOf(false), settingsRepository.lanSyncCalls)
        assertEquals(listOf(false), settingsRepository.cloudSyncCalls)
        assertEquals(listOf(150), settingsRepository.historyLimitCalls)
        assertEquals(listOf(5), settingsRepository.autoDeleteCalls)
    }
}
