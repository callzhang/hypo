package com.hypo.clipboard.sync

import android.content.ClipData
import android.content.ClipboardManager
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import io.mockk.every
import io.mockk.mockk
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Before

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClipboardPipelineTest {

    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val clipboardManager = context.getSystemService(ClipboardManager::class.java)
    private val identity = mockk<DeviceIdentity> {
        every { deviceId } returns "android-device"
    }
    private val syncEngine = mockk<SyncEngine>(relaxed = true)

    @Before
    fun setUp() {
        clipboardManager.clearPrimaryClip()
    }

    @Test
    fun processesTextClipEndToEnd() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val repository = RecordingRepository()
        val coordinator = SyncCoordinator(repository, syncEngine, identity)
        coordinator.start(this)

        val listener = ClipboardListener(
            clipboardManager = clipboardManager,
            parser = ClipboardParser(context.contentResolver),
            onClipboardChanged = { coordinator.onClipboardEvent(it) },
            scope = this,
            dispatcher = dispatcher
        )

        clipboardManager.setPrimaryClip(ClipData.newPlainText("label", "Hello from Hypo"))
        listener.start()
        advanceUntilIdle()

        assertEquals(1, repository.items.size)
        val item = repository.items.first()
        assertEquals(ClipboardType.TEXT, item.type)
        assertEquals("Hello from Hypo", item.content)
        assertEquals("Hello from Hypo", item.preview)

        listener.stop()
        coordinator.stop()
    }

    @Test
    fun processesImageClipEndToEnd() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val repository = RecordingRepository()
        val coordinator = SyncCoordinator(repository, syncEngine, identity)
        coordinator.start(this)

        val listener = ClipboardListener(
            clipboardManager = clipboardManager,
            parser = ClipboardParser(context.contentResolver),
            onClipboardChanged = { coordinator.onClipboardEvent(it) },
            scope = this,
            dispatcher = dispatcher
        )

        val file = File.createTempFile("hypo-image", ".png", context.cacheDir)
        file.outputStream().use { stream ->
            val bitmap = android.graphics.Bitmap.createBitmap(16, 16, android.graphics.Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(0xFFAA8844.toInt())
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 90, stream)
        }
        val uri = Uri.fromFile(file)
        clipboardManager.setPrimaryClip(ClipData.newUri(context.contentResolver, "image", uri))

        listener.start()
        advanceUntilIdle()

        assertEquals(1, repository.items.size)
        val item = repository.items.first()
        assertEquals(ClipboardType.IMAGE, item.type)
        assertTrue(item.content.isNotEmpty())
        assertTrue(item.preview.startsWith("Image"))
        assertEquals("image/png", item.metadata?.get("mime_type"))

        listener.stop()
        coordinator.stop()
    }

    @Test
    fun processesFileClipEndToEnd() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val repository = RecordingRepository()
        val coordinator = SyncCoordinator(repository, syncEngine, identity)
        coordinator.start(this)

        val listener = ClipboardListener(
            clipboardManager = clipboardManager,
            parser = ClipboardParser(context.contentResolver),
            onClipboardChanged = { coordinator.onClipboardEvent(it) },
            scope = this,
            dispatcher = dispatcher
        )

        val file = File.createTempFile("hypo-doc", ".txt", context.cacheDir)
        file.writeText("Document contents for Hypo")
        val uri = Uri.fromFile(file)
        clipboardManager.setPrimaryClip(ClipData.newUri(context.contentResolver, "file", uri))

        listener.start()
        advanceUntilIdle()

        assertEquals(1, repository.items.size)
        val item = repository.items.first()
        assertEquals(ClipboardType.FILE, item.type)
        assertTrue(item.content.isNotEmpty())
        assertEquals(file.name, item.metadata?.get("filename"))

        listener.stop()
        coordinator.stop()
    }

    private class RecordingRepository : ClipboardRepository {
        private val state = MutableStateFlow<List<ClipboardItem>>(emptyList())
        val items: List<ClipboardItem>
            get() = state.value

        override fun observeHistory(limit: Int): Flow<List<ClipboardItem>> =
            state.map { items -> items.takeLast(limit) }

        override suspend fun upsert(item: ClipboardItem) {
            state.value = state.value + item
        }

        override suspend fun delete(id: String) {
            state.value = state.value.filterNot { it.id == id }
        }

        override suspend fun clear() {
            state.value = emptyList()
        }
    }
}
