package com.hypo.clipboard.ui.home

import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.fakes.FakeClipboardRepository
import com.hypo.clipboard.transport.ConnectionState
import com.hypo.clipboard.transport.TransportManager
import io.mockk.every
import io.mockk.mockk
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
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
class HomeViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val historyRepository = FakeClipboardRepository()
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
    fun `uiState reflects latest clipboard item and connection state`() = runTest {
        val newest = item(id = "2", preview = "World")
        val older = item(id = "1", preview = "Hello")
        historyRepository.setHistory(listOf(newest, older))

        val viewModel = HomeViewModel(historyRepository, transportManager)
        awaitState(viewModel.uiState, dispatcher) { it.latestItem == newest }
        assertEquals(newest, viewModel.uiState.value.latestItem)
        assertEquals(ConnectionState.Disconnected, viewModel.uiState.value.connectionState)

        connectionState.value = ConnectionState.ConnectedCloud
        awaitState(viewModel.uiState, dispatcher) { it.connectionState == ConnectionState.ConnectedCloud }
        assertEquals(ConnectionState.ConnectedCloud, viewModel.uiState.value.connectionState)
        viewModel.viewModelScope.cancel()
    }

    @Test
    fun `uiState clears latest item when history empties`() = runTest {
        val viewModel = HomeViewModel(historyRepository, transportManager)
        awaitState(viewModel.uiState, dispatcher) { it.latestItem == null }
        assertNull(viewModel.uiState.value.latestItem)

        historyRepository.setHistory(listOf(item(id = "1", preview = "Hello")))
        awaitState(viewModel.uiState, dispatcher) { it.latestItem?.preview == "Hello" }
        assertEquals("Hello", viewModel.uiState.value.latestItem?.preview)

        historyRepository.setHistory(emptyList())
        awaitState(viewModel.uiState, dispatcher) { it.latestItem == null }
        assertNull(viewModel.uiState.value.latestItem)
        viewModel.viewModelScope.cancel()
    }

    private fun item(id: String, preview: String) = ClipboardItem(
        id = id,
        type = ClipboardType.TEXT,
        content = preview.lowercase(),
        preview = preview,
        metadata = null,
        deviceId = "device",
        createdAt = Instant.parse("2024-01-01T00:00:00Z"),
        isPinned = false
    )

    private suspend fun awaitState(
        state: StateFlow<HomeUiState>,
        dispatcher: TestDispatcher,
        predicate: (HomeUiState) -> Boolean
    ) {
        repeat(100) {
            dispatcher.scheduler.advanceUntilIdle()
            if (predicate(state.value)) return
            yield()
        }
        throw AssertionError("State did not reach the expected condition.")
    }
}
