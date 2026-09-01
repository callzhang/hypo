package com.hypo.clipboard.sync

import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import java.time.Clock
import java.time.Duration
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Remembers what this device just applied from a peer, so the copy the system
 * reports a moment later is recognised as that same content returning rather than
 * as something the user copied.
 *
 * Byte comparison cannot do this. An image is re-encoded on the way round -- the
 * sender compresses it, a platform re-encodes it on the way onto the clipboard --
 * so its bytes differ every hop while it is plainly the same picture. Two devices
 * each seeing "a picture I have never seen" is how one screenshot circulated
 * between a Mac and a phone for minutes, adding a history entry each pass.
 *
 * Shape is the stable part: pixel dimensions for an image, the string itself for
 * text. Time-bounded, because copying the same thing again a minute later is a
 * real second copy that the user expects to sync.
 */
@Singleton
class ClipboardEchoGuard @Inject constructor() {

    /** Overridable so tests need not sleep. */
    internal var clock: Clock = Clock.systemUTC()

    private var lastApplied: Pair<String, Instant>? = null

    /** Records content this device has just put on the clipboard on a peer's behalf. */
    @Synchronized
    fun recordApplied(item: ClipboardItem) {
        lastApplied = shapeOf(item) to Instant.now(clock)
    }

    /**
     * True when [item] is a local capture of content we applied moments ago.
     * Consumes the record: the echo arrives once, and a genuine re-copy after it
     * should still get through.
     */
    @Synchronized
    fun isEchoOfAppliedContent(item: ClipboardItem): Boolean {
        val (shape, at) = lastApplied ?: return false
        if (Duration.between(at, Instant.now(clock)) >= ECHO_WINDOW) {
            lastApplied = null
            return false
        }
        if (shape != shapeOf(item)) return false
        lastApplied = null
        return true
    }

    @Synchronized
    fun reset() {
        lastApplied = null
    }

    private fun shapeOf(item: ClipboardItem): String = when (item.type) {
        ClipboardType.IMAGE -> {
            val width = item.metadata?.get("width")
            val height = item.metadata?.get("height")
            if (width != null && height != null) "image:${width}x${height}" else "image:${item.content.length}"
        }
        ClipboardType.FILE -> "file:${item.metadata?.get("file_name") ?: ""}-${item.content.length}"
        else -> "text:${item.content}"
    }

    companion object {
        /**
         * Long enough to cover applying, the system reporting the change and any
         * re-encoding on the way; short enough that a deliberate second copy of the
         * same thing still syncs.
         */
        internal val ECHO_WINDOW: Duration = Duration.ofSeconds(20)
    }
}
