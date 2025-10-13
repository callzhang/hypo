package com.hypo.clipboard.sync

import android.util.Log
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SyncCoordinator @Inject constructor(
    private val repository: ClipboardRepository,
    private val syncEngine: SyncEngine,
    private val identity: DeviceIdentity
) {
    private var eventChannel: Channel<ClipboardEvent>? = null
    private var job: Job? = null
    private val targets = MutableStateFlow<Set<String>>(emptySet())

    fun start(scope: CoroutineScope) {
        if (job != null) {
            Log.i(TAG, "⚠️  SyncCoordinator already started")
            return
        }
        Log.i(TAG, "🚀 SyncCoordinator STARTING...")
        val channel = Channel<ClipboardEvent>(Channel.BUFFERED)
        eventChannel = channel
        job = scope.launch {
            Log.i(TAG, "✅ SyncCoordinator event loop RUNNING, waiting for events...")
            for (event in channel) {
                Log.i(TAG, "📨 Received clipboard event! Type: ${event.type}, id: ${event.id}")
                val item = ClipboardItem(
                    id = event.id,
                    type = event.type,
                    content = event.content,
                    preview = event.preview,
                    metadata = event.metadata.ifEmpty { emptyMap() },
                    deviceId = identity.deviceId,
                    createdAt = event.createdAt,
                    isPinned = false
                )
                Log.i(TAG, "💾 Upserting item to repository...")
                repository.upsert(item)
                Log.i(TAG, "✅ Item saved to database!")

                targets.value.forEach { target ->
                    Log.i(TAG, "📤 Syncing to target: $target")
                    runCatching { syncEngine.sendClipboard(item, target) }
                }
            }
        }
    }

    fun stop() {
        eventChannel?.close()
        eventChannel = null
        job?.cancel()
        job = null
    }

    suspend fun onClipboardEvent(event: ClipboardEvent) {
        Log.i(TAG, "📬 onClipboardEvent called! Sending to channel...")
        eventChannel?.send(event)
        Log.i(TAG, "✅ Event sent to channel successfully")
    }

    fun setTargetDevices(deviceIds: Set<String>) {
        targets.value = deviceIds
    }

    companion object {
        private const val TAG = "SyncCoordinator"
    }
}
