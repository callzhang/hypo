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

    fun onClipboardEvent(event: ClipboardEvent) {
        // Use tryEmit() to avoid suspending and handle the case where events are dropped
        // Returns false if buffer is full or there's no collector, preventing crashes
        val success = events.tryEmit(event)
        if (!success) {
            // Event was dropped - either buffer is full or no active collector
            // This is expected behavior when stopped or buffer is full
            android.util.Log.w("SyncCoordinator", "Clipboard event dropped - coordinator may not be started or buffer full")
        }
    }

    fun setTargetDevices(deviceIds: Set<String>) {
        targets.value = deviceIds
    }
}
