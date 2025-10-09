package com.hypo.clipboard.ui.history

import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.fakes.FakeClipboardRepository
import com.hypo.clipboard.fakes.FakeSettingsRepository
import java.time.Instant
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain

@OptIn(ExperimentalCoroutinesApi::class)
class HistoryViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val repository = FakeClipboardRepository()
    private val settingsRepository = FakeSettingsRepository()

    @BeforeTest
    fun setUp() {
        setMain(dispatcher)
    }

    @AfterTest
    fun tearDown() {
        resetMain()
    }

    @Test
    fun `state reflects history limited by settings`() = runTest {
        settingsRepository.emit(UserSettings(historyLimit = 2))
        repository.setHistory(listOf(item("1", "alpha"), item("2", "beta"), item("3", "gamma")))

        val viewModel = HistoryViewModel(repository, settingsRepository)
        runCurrent()

        assertEquals(listOf("alpha", "beta"), viewModel.state.value.items.map { it.preview })
        assertEquals(2, viewModel.state.value.totalItems)
        assertEquals(2, viewModel.state.value.historyLimit)
    }

    @Test
    fun `query filters history ignoring case`() = runTest {
        repository.setHistory(listOf(item("1", "Hello"), item("2", "World")))
        val viewModel = HistoryViewModel(repository, settingsRepository)
        runCurrent()

        viewModel.onQueryChange("world")
        runCurrent()

        assertEquals(listOf("World"), viewModel.state.value.items.map { it.preview })
        assertEquals("world", viewModel.state.value.query)
    }

    @Test
    fun `clearHistory delegates to repository`() = runTest {
        val viewModel = HistoryViewModel(repository, settingsRepository)
        runCurrent()

        viewModel.clearHistory()
        runCurrent()

        assertEquals(1, repository.clearCallCount)
    }

    private fun item(id: String, preview: String) = ClipboardItem(
        id = id,
        type = ClipboardType.Text,
        content = preview,
        preview = preview,
        metadata = null,
        deviceId = "device",
        createdAt = Instant.parse("2024-01-01T00:00:00Z"),
        isPinned = false
    )
}
