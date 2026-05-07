package com.hypo.clipboard.ui.history

import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals

class HistoryDetailSaveTest {
    @Test
    fun `image save mime uses explicit image mime type`() {
        val item = imageItem(
            id = "image-id",
            metadata = mapOf("mime_type" to "image/webp", "format" to "png")
        )

        assertEquals("image/webp", resolveImageSaveMimeType(item))
    }

    @Test
    fun `image save mime maps captured image format`() {
        val item = imageItem(
            id = "image-id",
            metadata = mapOf("format" to "jpg")
        )

        assertEquals("image/jpeg", resolveImageSaveMimeType(item))
    }

    @Test
    fun `image save filename sanitizes metadata filename and keeps extension`() {
        val item = imageItem(
            id = "image-id",
            metadata = mapOf("file_name" to "clip:from/mac?.png")
        )

        assertEquals("clip_from_mac_.png", resolveImageSaveFileName(item))
    }

    @Test
    fun `image save filename falls back to stable hypo name with inferred extension`() {
        val item = imageItem(
            id = "1234567890abcdef",
            metadata = mapOf("format" to "webp")
        )

        assertEquals("hypo-image-12345678.webp", resolveImageSaveFileName(item))
    }

    private fun imageItem(
        id: String,
        metadata: Map<String, String>?
    ): ClipboardItem {
        return ClipboardItem(
            id = id,
            type = ClipboardType.IMAGE,
            content = "",
            preview = "",
            metadata = metadata,
            deviceId = "device",
            createdAt = Instant.parse("2026-05-05T00:00:00Z"),
            isPinned = false
        )
    }
}
