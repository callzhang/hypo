package com.hypo.clipboard.sync

import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
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
        if (job != null) return
        val channel = Channel<ClipboardEvent>(Channel.BUFFERED)
        eventChannel = channel
        job = scope.launch {
            for (event in channel) {
                val item = ClipboardItem(
                    id = event.id,
                    type = ClipboardType.TEXT,
                    content = event.text,
                    preview = event.text.take(64),
                    metadata = emptyMap(),
                    deviceId = identity.deviceId,
                    createdAt = event.createdAt,
                    isPinned = false
                )
                repository.upsert(item)

                targets.value.forEach { target ->
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
        eventChannel?.send(event)
    }

    fun setTargetDevices(deviceIds: Set<String>) {
        targets.value = deviceIds
    }
}
