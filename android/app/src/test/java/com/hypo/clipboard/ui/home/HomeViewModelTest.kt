package com.hypo.clipboard.ui.home

import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.fakes.FakeClipboardRepository
import com.hypo.clipboard.transport.ConnectionState
import com.hypo.clipboard.transport.TransportManager
import io.mockk.every
import io.mockk.mockk
import java.time.Instant
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class HomeViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val historyRepository = FakeClipboardRepository()
    private val connectionState = MutableStateFlow(ConnectionState.Idle)
    private val transportManager: TransportManager = mockk(relaxed = true) {
        every { this@mockk.connectionState } returns connectionState
    }

    @BeforeTest
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @AfterTest
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `uiState reflects latest clipboard item and connection state`() = runTest {
        val newest = item(id = "2", preview = "World")
        val older = item(id = "1", preview = "Hello")
        historyRepository.setHistory(listOf(newest, older))

        val viewModel = HomeViewModel(historyRepository, transportManager)

        runCurrent()
        assertEquals(newest, viewModel.uiState.value.latestItem)
        assertEquals(ConnectionState.Idle, viewModel.uiState.value.connectionState)

        connectionState.value = ConnectionState.ConnectedCloud
        runCurrent()

        assertEquals(ConnectionState.ConnectedCloud, viewModel.uiState.value.connectionState)
    }

    @Test
    fun `uiState clears latest item when history empties`() = runTest {
        val viewModel = HomeViewModel(historyRepository, transportManager)
        runCurrent()
        assertNull(viewModel.uiState.value.latestItem)

        historyRepository.setHistory(listOf(item(id = "1", preview = "Hello")))
        runCurrent()
        assertEquals("Hello", viewModel.uiState.value.latestItem?.preview)

        historyRepository.setHistory(emptyList())
        runCurrent()
        assertNull(viewModel.uiState.value.latestItem)
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
}
