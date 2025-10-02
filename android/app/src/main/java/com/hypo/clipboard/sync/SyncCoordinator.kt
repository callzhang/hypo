package com.hypo.clipboard.sync

import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
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
    private val events = MutableSharedFlow<ClipboardEvent>(extraBufferCapacity = 16)
    private var job: Job? = null
    private val targets = MutableStateFlow<Set<String>>(emptySet())

    fun start(scope: CoroutineScope) {
        if (job != null) return
        job = scope.launch(Dispatchers.IO) {
            events.collect { event ->
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
        job?.cancel()
        job = null
    }

    suspend fun onClipboardEvent(event: ClipboardEvent) {
        events.emit(event)
    }

    fun setTargetDevices(deviceIds: Set<String>) {
        targets.value = deviceIds
    }
}
