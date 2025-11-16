package com.hypo.clipboard.sync

import android.util.Log
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SyncCoordinator @Inject constructor(
    private val repository: ClipboardRepository,
    private val syncEngine: SyncEngine,
    private val identity: DeviceIdentity,
    private val transportManager: com.hypo.clipboard.transport.TransportManager
) {
    private var eventChannel: Channel<ClipboardEvent>? = null
    private var job: Job? = null
    private val autoTargets = MutableStateFlow<Set<String>>(emptySet())
    private val manualTargets = MutableStateFlow<Set<String>>(emptySet())
    private val _targets = MutableStateFlow<Set<String>>(emptySet())
    val targets: StateFlow<Set<String>> = _targets.asStateFlow()
    
    init {
        // Observe transport manager peers to get auto-discovered devices
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Default).launch {
            transportManager.peers.collect { peers ->
                val deviceIds = peers.map { it.attributes["device_id"] ?: it.serviceName }.toSet()
                autoTargets.value = deviceIds
                recomputeTargets()
                android.util.Log.i(TAG, "🔄 Auto targets updated: ${deviceIds.size}, total=${_targets.value.size}")
            }
        }
    }

    private fun recomputeTargets() {
        // Combine auto and manual targets, but exclude local device ID (don't sync to ourselves)
        val combined = (autoTargets.value + manualTargets.value) - identity.deviceId
        _targets.value = combined
        Log.d(TAG, "🎯 Recomputed targets: auto=${autoTargets.value.size}, manual=${manualTargets.value.size}, combined=${combined.size}, localDeviceId=${identity.deviceId}")
    }

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
                // Use source device info if available (from remote sync), otherwise use local device info
                val deviceId = event.sourceDeviceId ?: identity.deviceId
                val deviceName = event.sourceDeviceName ?: identity.deviceName
                
                val item = ClipboardItem(
                    id = event.id,
                    type = event.type,
                    content = event.content,
                    preview = event.preview,
                    metadata = event.metadata.ifEmpty { emptyMap() },
                    deviceId = deviceId,
                    deviceName = deviceName,
                    createdAt = event.createdAt,
                    isPinned = false
                )
                Log.i(TAG, "💾 Upserting item to repository...")
                Log.i(TAG, "📱 Device Info: deviceId=${deviceId.take(20)}..., fullId=$deviceId, deviceName=$deviceName, isRemote=${event.sourceDeviceId != null}, skipBroadcast=${event.skipBroadcast}")
                repository.upsert(item)
                Log.i(TAG, "✅ Item saved to database!")

                // Only broadcast if not a received item (prevent loops)
                if (!event.skipBroadcast) {
                    val pairedDevices = _targets.value
                    if (pairedDevices.isNotEmpty()) {
                        Log.i(TAG, "📤 Broadcasting to ${pairedDevices.size} paired devices")
                        pairedDevices.forEach { target ->
                            Log.i(TAG, "📤 Syncing to device: ${target.take(20)}...")
                            runCatching { syncEngine.sendClipboard(item, target) }
                                .onFailure { error -> Log.e(TAG, "Failed to sync to $target: ${error.message}") }
                        }
                    } else {
                        Log.i(TAG, "⏭️  No paired devices to broadcast to")
                    }
                } else {
                    Log.i(TAG, "⏭️  Skipping broadcast (received from remote)")
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
        Log.d(TAG, "🎯 setTargetDevices called with: $deviceIds")
        manualTargets.value = deviceIds
        recomputeTargets()
        Log.d(TAG, "✅ Target devices updated: ${_targets.value}")
    }

    fun addTargetDevice(deviceId: String) {
        manualTargets.update { it + deviceId }
        recomputeTargets()
        Log.i(TAG, "➕ Added manual sync target: $deviceId")
    }

    fun removeTargetDevice(deviceId: String) {
        manualTargets.update { it - deviceId }
        recomputeTargets()
        Log.i(TAG, "➖ Removed manual sync target: $deviceId")
    }

    companion object {
        private const val TAG = "SyncCoordinator"
    }
}
