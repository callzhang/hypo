package com.hypo.clipboard.sync

import android.content.ClipData
import android.content.ClipboardManager
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class ClipboardListener(
    private val clipboardManager: ClipboardManager,
    private val parser: ClipboardParser,
    private val onClipboardChanged: suspend (ClipboardEvent) -> Unit,
    private val scope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default
) : ClipboardManager.OnPrimaryClipChangedListener {

    private var lastSignature: String? = null
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
        val event = parser.parse(clip) ?: return
        val signature = event.signature()
        if (lastSignature == signature) return
        lastSignature = signature

        job?.cancel()
        job = scope.launch(dispatcher) {
            onClipboardChanged(event)
        }
    }
}
