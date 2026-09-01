package com.hypo.clipboard.sync

import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test

class ClipboardEchoGuardTest {

    private var now: Instant = Instant.parse("2026-08-31T12:00:00Z")

    private fun guard(): ClipboardEchoGuard = ClipboardEchoGuard().also {
        it.clock = object : Clock() {
            override fun getZone() = ZoneOffset.UTC
            override fun withZone(zone: java.time.ZoneId?) = this
            override fun instant() = now
        }
    }

    private fun image(content: String, width: Int = 1091, height: Int = 326) = ClipboardItem(
        id = "id-$content",
        type = ClipboardType.IMAGE,
        content = content,
        preview = "Image",
        metadata = mapOf("width" to width.toString(), "height" to height.toString()),
        deviceId = "device",
        createdAt = now,
        isPinned = false
    )

    /** The whole point: the picture that comes back is not byte-identical. */
    @Test
    fun `recognises a re-encoded image as the one just applied`() {
        val guard = guard()
        guard.recordApplied(image("png-bytes-as-base64"))

        assertTrue(guard.isEchoOfAppliedContent(image("jpeg-bytes-entirely-different")))
    }

    @Test
    fun `a different picture is not an echo`() {
        val guard = guard()
        guard.recordApplied(image("bytes", width = 1091, height = 326))

        assertFalse(guard.isEchoOfAppliedContent(image("bytes", width = 406, height = 550)))
    }

    /** Copying the same thing again later is a real second copy. */
    @Test
    fun `stops suppressing once the window passes`() {
        val guard = guard()
        guard.recordApplied(image("bytes"))
        now = now.plus(ClipboardEchoGuard.ECHO_WINDOW).plusSeconds(1)

        assertFalse(guard.isEchoOfAppliedContent(image("bytes")))
    }

    /** One apply produces one echo; the next copy of it is the user's own. */
    @Test
    fun `suppresses only the first echo`() {
        val guard = guard()
        guard.recordApplied(image("bytes"))

        assertTrue(guard.isEchoOfAppliedContent(image("other-bytes")))
        assertFalse(guard.isEchoOfAppliedContent(image("other-bytes")))
    }

    @Test
    fun `matches text by its content`() {
        val guard = guard()
        val text = ClipboardItem(
            id = "t",
            type = ClipboardType.TEXT,
            content = "hello",
            preview = "hello",
            metadata = null,
            deviceId = "device",
            createdAt = now,
            isPinned = false
        )
        guard.recordApplied(text)

        assertTrue(guard.isEchoOfAppliedContent(text.copy(id = "t2")))
    }
}
