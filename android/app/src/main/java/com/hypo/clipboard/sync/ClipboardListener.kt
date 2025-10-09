package com.hypo.clipboard.sync

import android.content.ClipData
import android.content.ClipboardManager
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.UUID

class ClipboardListener(
    private val clipboardManager: ClipboardManager,
    private val onClipboardChanged: suspend (ClipboardEvent) -> Unit,
    private val scope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default
) : ClipboardManager.OnPrimaryClipChangedListener {

    private var lastHash: Int? = null
    private var job: Job? = null
    private var isListening: Boolean = false

    fun start() {
        if (isListening) return
        clipboardManager.addPrimaryClipChangedListener(this)
        clipboardManager.primaryClip?.let { clip ->
            process(clip)
        }
        isListening = true
    }

    fun stop() {
        if (!isListening) return
        clipboardManager.removePrimaryClipChangedListener(this)
        job?.cancel()
        job = null
        isListening = false
    }

    override fun onPrimaryClipChanged() {
        clipboardManager.primaryClip?.let { clip ->
            process(clip)
        }
    }

    private fun process(clip: ClipData) {
        val item = clip.getItemAt(0)
        val text = item.coerceToText(null)?.toString()?.trim() ?: return
        val hash = text.hashCode()
        if (lastHash == hash) return
        lastHash = hash

        job?.cancel()
        job = scope.launch(dispatcher) {
            onClipboardChanged(
                ClipboardEvent(
                    id = UUID.randomUUID().toString(),
                    text = text,
                    createdAt = Instant.now()
                )
            )
        }
    }
}

data class ClipboardEvent(
    val id: String,
    val text: String,
    val createdAt: Instant
)
