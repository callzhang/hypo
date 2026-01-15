package com.hypo.clipboard.ui.history

import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.fakes.FakeClipboardRepository
import com.hypo.clipboard.fakes.FakeSettingsRepository
import com.hypo.clipboard.transport.ConnectionState
import com.hypo.clipboard.transport.TransportManager
import io.mockk.every
import io.mockk.mockk
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.yield
import org.junit.runner.RunWith
import org.junit.After
import org.junit.Before
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class HistoryViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val repository = FakeClipboardRepository()
    private val settingsRepository = FakeSettingsRepository()
    private val identity = mockk<com.hypo.clipboard.sync.DeviceIdentity> {
        every { deviceId } returns "device"
    }
    private val connectionState = MutableStateFlow(ConnectionState.Disconnected)
    private val transportManager: TransportManager = mockk(relaxed = true)

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
        every { transportManager.cloudConnectionState } returns connectionState
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `state reflects history limited by settings`() = runTest {
        settingsRepository.emit(UserSettings(historyLimit = 2))
        repository.setHistory(listOf(item("1", "alpha"), item("2", "beta"), item("3", "gamma")))

        val viewModel = HistoryViewModel(repository, settingsRepository, identity, transportManager)
        awaitState(viewModel.state, dispatcher) { it.items.isNotEmpty() }
        assertEquals(listOf("alpha", "beta"), viewModel.state.value.items.map { it.preview })
        assertEquals(2, viewModel.state.value.totalItems)
        assertEquals(2, viewModel.state.value.historyLimit)
        viewModel.viewModelScope.cancel()
    }

    @Test
    fun `query filters history ignoring case`() = runTest {
        repository.setHistory(listOf(item("1", "Hello"), item("2", "World")))
        val viewModel = HistoryViewModel(repository, settingsRepository, identity, transportManager)
        awaitState(viewModel.state, dispatcher) { it.items.isNotEmpty() }

        viewModel.onQueryChange("world")
        awaitState(viewModel.state, dispatcher) { it.query == "world" }

        assertEquals(listOf("World"), viewModel.state.value.items.map { it.preview })
        assertEquals("world", viewModel.state.value.query)
        viewModel.viewModelScope.cancel()
    }

    @Test
    fun `clearHistory delegates to repository`() = runTest {
        repository.setHistory(listOf(item("1", "alpha"), item("2", "beta")))
        val viewModel = HistoryViewModel(repository, settingsRepository, identity, transportManager)
        awaitState(viewModel.state, dispatcher) { it.items.isNotEmpty() }

        viewModel.clearHistory()
        awaitState(viewModel.state, dispatcher) { it.items.isEmpty() }

        assertEquals(1, repository.clearCallCount)
        viewModel.viewModelScope.cancel()
    }

    private fun item(id: String, preview: String) = ClipboardItem(
        id = id,
        type = ClipboardType.TEXT,
        content = preview,
        preview = preview,
        metadata = null,
        deviceId = "device",
        createdAt = Instant.parse("2024-01-01T00:00:00Z"),
        isPinned = false
    )

    private suspend fun awaitState(
        state: StateFlow<HistoryUiState>,
        dispatcher: TestDispatcher,
        predicate: (HistoryUiState) -> Boolean
    ) {
        repeat(100) {
            dispatcher.scheduler.advanceUntilIdle()
            if (predicate(state.value)) return
            yield()
        }
        throw AssertionError("State did not reach the expected condition. Last state: ${state.value}")
    }
}
