package com.hypo.clipboard.sync

import android.content.ClipData
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import com.hypo.clipboard.domain.model.ClipboardType
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClipboardParserTest {

    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val parser = ClipboardParser(context.contentResolver)

    @Test
    fun parsesPlainTextClip() {
        val clip = ClipData.newPlainText("label", "Hello Hypo")

        val event = parser.parse(clip)

        assertNotNull(event)
        assertEquals(ClipboardType.TEXT, event.type)
        assertEquals("Hello Hypo", event.content)
        assertEquals("Hello Hypo", event.preview)
        assertTrue(event.metadata.containsKey("hash"))
        assertEquals("UTF-8", event.metadata["encoding"])
        assertEquals("${"Hello Hypo".encodeToByteArray().size}", event.metadata["size"])
        assertTrue(event.createdAt.isAfter(Instant.now().minusSeconds(60)))
    }

    @Test
    fun parsesLinkClip() {
        val clip = ClipData.newPlainText("label", "https://hypo.app")

        val event = parser.parse(clip)

        assertNotNull(event)
        assertEquals(ClipboardType.LINK, event.type)
        assertEquals("https://hypo.app", event.content)
        assertTrue(event.preview.startsWith("https://hypo.app"))
        assertEquals("text/uri-list", event.metadata["mime_type"])
    }

    @Test
    fun parsesImageFromFileUri() {
        val file = File.createTempFile("hypo", ".png", context.cacheDir)
        file.outputStream().use { stream ->
            val bitmap = android.graphics.Bitmap.createBitmap(10, 20, android.graphics.Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(0xFF336699.toInt())
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, stream)
        }
        val uri = Uri.fromFile(file)
        val clip = ClipData.newUri(context.contentResolver, "image", uri)

        val event = parser.parse(clip)

        assertNotNull(event)
        assertEquals(ClipboardType.IMAGE, event.type)
        assertTrue(event.content.isNotEmpty())
        assertTrue(event.preview.startsWith("Image"))
        assertEquals("10", event.metadata["width"])
        assertEquals("20", event.metadata["height"])
        assertEquals("image/png", event.metadata["mime_type"])
        assertTrue(event.metadata.containsKey("thumbnail_base64"))
    }

    @Test
    fun parsesFileFromUri() {
        val file = File.createTempFile("hypo", ".txt", context.cacheDir)
        FileOutputStream(file).use { it.write("Hello file".encodeToByteArray()) }
        val uri = Uri.fromFile(file)
        val clip = ClipData.newUri(context.contentResolver, "file", uri)

        val event = parser.parse(clip)

        assertNotNull(event)
        assertEquals(ClipboardType.FILE, event.type)
        assertEquals(file.name, event.metadata["filename"])
        assertEquals("text/plain", event.metadata["mime_type"])
        assertTrue(event.content.isNotEmpty())
        assertTrue(event.preview.contains(file.name))
    }
}
