package com.hypo.clipboard.sync

import android.content.ClipData
import android.content.ClipboardManager
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClipboardPipelineTest {

    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val clipboardManager = context.getSystemService(ClipboardManager::class.java)
    private val identity = mockk<DeviceIdentity> {
        every { deviceId } returns "android-device"
        every { deviceName } returns "Pixel"
    }
    private val syncEngine = mockk<SyncEngine>(relaxed = true)
    private val transportManager = mockk<com.hypo.clipboard.transport.TransportManager>(relaxed = true) {
        every { peers } returns MutableStateFlow(emptyList())
    }
    private val deviceKeyStore = mockk<DeviceKeyStore>(relaxed = true) {
        coEvery { getAllDeviceIds() } returns listOf("mac-device")
    }
    private val lanTransportClient = mockk<com.hypo.clipboard.transport.ws.WebSocketTransportClient>(relaxed = true)

    @Before
    fun setUp() {
        clipboardManager.clearPrimaryClip()
    }

    @Test
    fun processesTextClipEndToEnd() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val repository = RecordingRepository()
        val coordinator = SyncCoordinator(
            repository = repository,
            syncEngine = syncEngine,
            identity = identity,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            context = context
        )
        coordinator.start(this)

        val listener = ClipboardListener(
            clipboardManager = clipboardManager,
            parser = ClipboardParser(
                context.contentResolver,
                com.hypo.clipboard.data.local.StorageManager(context)
            ),
            onClipboardChanged = { coordinator.onClipboardEvent(it) },
            scope = this,
            dispatcher = dispatcher
        )

        listener.start()
        clipboardManager.setPrimaryClip(ClipData.newPlainText("label", "Hello from Hypo"))
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
        val coordinator = SyncCoordinator(
            repository = repository,
            syncEngine = syncEngine,
            identity = identity,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            context = context
        )
        coordinator.start(this)

        val listener = ClipboardListener(
            clipboardManager = clipboardManager,
            parser = ClipboardParser(
                context.contentResolver,
                com.hypo.clipboard.data.local.StorageManager(context)
            ),
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
        listener.start()
        clipboardManager.setPrimaryClip(ClipData.newUri(context.contentResolver, "image", uri))
        advanceUntilIdle()

        assertEquals(1, repository.items.size)
        val item = repository.items.first()
        assertEquals(ClipboardType.IMAGE, item.type)
        assertTrue(item.content.isNotEmpty() || item.localPath != null)
        assertTrue(item.preview.startsWith("Image"))
        assertEquals("image/png", item.metadata?.get("mime_type"))

        listener.stop()
        coordinator.stop()
    }

    @Test
    fun processesFileClipEndToEnd() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val repository = RecordingRepository()
        val coordinator = SyncCoordinator(
            repository = repository,
            syncEngine = syncEngine,
            identity = identity,
            transportManager = transportManager,
            deviceKeyStore = deviceKeyStore,
            lanTransportClient = lanTransportClient,
            context = context
        )
        coordinator.start(this)

        val listener = ClipboardListener(
            clipboardManager = clipboardManager,
            parser = ClipboardParser(
                context.contentResolver,
                com.hypo.clipboard.data.local.StorageManager(context)
            ),
            onClipboardChanged = { coordinator.onClipboardEvent(it) },
            scope = this,
            dispatcher = dispatcher
        )

        val file = File.createTempFile("hypo-doc", ".txt", context.cacheDir)
        file.writeText("Document contents for Hypo")
        val uri = Uri.fromFile(file)
        listener.start()
        clipboardManager.setPrimaryClip(ClipData.newUri(context.contentResolver, "file", uri))
        advanceUntilIdle()

        assertEquals(1, repository.items.size)
        val item = repository.items.first()
        assertEquals(ClipboardType.FILE, item.type)
        assertTrue(item.content.isNotEmpty() || item.localPath != null)
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

        override suspend fun getLatestEntry(): ClipboardItem? = state.value.firstOrNull()

        override suspend fun findMatchingEntryInHistory(item: ClipboardItem): ClipboardItem? {
            return state.value.firstOrNull { it.content == item.content && it.type == item.type }
        }

        override suspend fun updateTimestamp(id: String, newTimestamp: java.time.Instant) {
            state.value = state.value.map { existing ->
                if (existing.id == id) existing.copy(createdAt = newTimestamp) else existing
            }
        }

        override suspend fun loadFullContent(itemId: String): String? {
            return state.value.firstOrNull { it.id == itemId }?.content
        }
    }
}
