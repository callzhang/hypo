package com.hypo.clipboard.sync

import android.util.Log
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SyncCoordinator @Inject constructor(
    private val repository: ClipboardRepository,
    private val syncEngine: SyncEngine,
    private val identity: DeviceIdentity,
    private val transportManager: com.hypo.clipboard.transport.TransportManager,
    private val deviceKeyStore: DeviceKeyStore,
    private val lanWebSocketClient: com.hypo.clipboard.transport.ws.LanWebSocketClient
) {
    private var eventChannel: Channel<ClipboardEvent>? = null
    private var job: Job? = null
    private val autoTargets = MutableStateFlow<Set<String>>(emptySet())
    private val manualTargets = MutableStateFlow<Set<String>>(emptySet())
    private val _targets = MutableStateFlow<Set<String>>(emptySet())
    val targets: StateFlow<Set<String>> = _targets.asStateFlow()
    private val keyStoreScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val pairedDeviceIdsCache = MutableStateFlow<Set<String>>(emptySet())
    
    init {
        // Initial load of paired device IDs (event-driven updates happen in addTargetDevice/removeTargetDevice)
        keyStoreScope.launch {
            try {
                val deviceIds = deviceKeyStore.getAllDeviceIds().toSet()
                pairedDeviceIdsCache.value = deviceIds
                recomputeTargets()
                Log.d(TAG, "📋 Initial paired device IDs loaded: ${deviceIds.size} devices")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Failed to load initial paired device IDs: ${e.message}")
            }
        }
        
        // Observe transport manager peers to get auto-discovered devices
        keyStoreScope.launch {
            transportManager.peers.collect { peers ->
                val deviceIds = peers.map { it.attributes["device_id"] ?: it.serviceName }.toSet()
                autoTargets.value = deviceIds
                recomputeTargets()
                
                // When paired peers are discovered, start maintaining a connection to receive messages
                val allowed = pairedDeviceIdsCache.value
                lanWebSocketClient.setAllowedDeviceIdsProvider { pairedDeviceIdsCache.value }
                val pairedPeers = peers.filter { p ->
                    val id = p.attributes["device_id"] ?: p.serviceName
                    allowed.any { it.equals(id, ignoreCase = true) }
                }
                if (pairedPeers.isNotEmpty()) {
                    android.util.Log.d(TAG, "🔌 Paired peers discovered (${pairedPeers.size}), starting receiving connection...")
                    lanWebSocketClient.startReceiving()
                } else if (allowed.isNotEmpty()) {
                    // We have paired devices (even if not currently discovered), maintain connection
                    // This ensures we can receive messages when peers come back online
                    android.util.Log.d(TAG, "ℹ️ No paired peers currently discovered, but ${allowed.size} paired device(s) exist - maintaining LAN receive loop")
                    lanWebSocketClient.startReceiving()
                } else {
                    android.util.Log.d(TAG, "ℹ️ No paired devices and no paired peers discovered; not starting LAN receive loop")
                }
            }
        }
    }

    private fun recomputeTargets() {
        // Combine auto and manual targets, but exclude local device ID (don't sync to ourselves)
        // CRITICAL: Only include devices that have encryption keys (paired devices)
        // This prevents sync attempts to unpaired devices or Android devices
        val allCandidates = (autoTargets.value + manualTargets.value) - identity.deviceId
        
        // Get all paired device IDs (devices with keys in the key store)
        val pairedDeviceIds = pairedDeviceIdsCache.value
        
        // IMPORTANT: Include ALL paired devices as targets, not just discovered ones
        // This ensures we can sync to paired devices even if they're not currently discovered
        // (e.g., macOS device on different network, temporarily offline, etc.)
        val allPairedTargets = pairedDeviceIds - identity.deviceId
        
        // Filter discovered candidates to only those that are paired
        val discoveredAndPaired = allCandidates.filter { candidateId ->
            // Try exact match first
            val exactMatch = pairedDeviceIds.contains(candidateId)
            if (exactMatch) {
                true
            } else {
                // Try case-insensitive match
                val caseInsensitiveMatch = pairedDeviceIds.any { it.equals(candidateId, ignoreCase = true) }
                if (caseInsensitiveMatch) {
                    Log.w(TAG, "⚠️ Device ID case mismatch: candidate=$candidateId, found in store (case-insensitive)")
                }
                caseInsensitiveMatch
            }
        }.toSet()
        
        // Combine: all paired devices (for sync even when not discovered) + discovered paired devices
        // This ensures we sync to all paired devices, whether discovered or not
        val filtered = (allPairedTargets + discoveredAndPaired).toSet()
        
        _targets.value = filtered
        Log.d(TAG, "🎯 Recomputed targets: auto=${autoTargets.value.size}, manual=${manualTargets.value.size}, candidates=${allCandidates.size}, paired=${pairedDeviceIds.size}, allPairedTargets=${allPairedTargets.size}, discoveredAndPaired=${discoveredAndPaired.size}, filtered=${filtered.size}, localDeviceId=${identity.deviceId}")
        
        if (filtered.size < allCandidates.size) {
            val missing = allCandidates - filtered
            Log.w(TAG, "⚠️ Excluded ${missing.size} devices without keys: $missing")
            Log.w(TAG, "📋 Available keys in store: $pairedDeviceIds")
            Log.w(TAG, "📋 Candidate device IDs: $allCandidates")
            // Log detailed mismatch info for debugging
            missing.forEach { candidateId ->
                val similar = pairedDeviceIds.find { 
                    it.equals(candidateId, ignoreCase = true) || 
                    it.contains(candidateId, ignoreCase = true) ||
                    candidateId.contains(it, ignoreCase = true)
                }
                if (similar != null) {
                    Log.w(TAG, "💡 Similar key found: candidate=$candidateId, similar=$similar (might be a format mismatch)")
                }
            }
        }
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
            for (event in channel) {
                // Use source device info if available (from remote sync), otherwise use local device info
                val deviceId = event.sourceDeviceId ?: identity.deviceId
                val deviceName = event.sourceDeviceName ?: identity.deviceName
                
                // Simplified duplicate detection (no time windows):
                // 1. If new message matches the current clipboard (latest entry) → discard
                // 2. If new message matches something in history → move that history item to the top
                // 3. Otherwise → add new entry
                
                // Create ClipboardItem from event for matching
                val eventItem = ClipboardItem(
                    id = event.id,
                    type = event.type,
                    content = event.content,
                    preview = event.preview,
                    metadata = event.metadata.ifEmpty { emptyMap() },
                    deviceId = deviceId,
                    deviceName = deviceName,
                    createdAt = event.createdAt,
                    isPinned = false,
                    isEncrypted = event.isEncrypted,
                    transportOrigin = event.transportOrigin
                )
                
                val latestEntry = repository.getLatestEntry()
                
                // Check if matches current clipboard (latest entry)
                val matchesCurrentClipboard = latestEntry?.let { latest ->
                    eventItem.matchesContent(latest)
                } ?: false
                
                if (matchesCurrentClipboard) {
                    android.util.Log.i(TAG, "⏭️ New message matches current clipboard, discarding: ${event.preview.take(50)}")
                    continue
                }
                
                // Check if matches something in history (excluding the latest entry)
                val matchingEntry = repository.findMatchingEntryInHistory(eventItem)
                
                val item: ClipboardItem
                if (matchingEntry != null) {
                    // Found matching entry in history - move it to the top by updating timestamp
                    val newTimestamp = Instant.now()
                    repository.updateTimestamp(matchingEntry.id, newTimestamp)
                    android.util.Log.i(TAG, "🔄 New message matches history item, moved to top: ${matchingEntry.preview.take(50)}")
                    // Use the existing item for broadcasting
                    item = matchingEntry
                } else {
                    // Not a duplicate - add to history
                    item = ClipboardItem(
                        id = event.id,
                        type = event.type,
                        content = event.content,
                        preview = event.preview,
                        metadata = event.metadata.ifEmpty { emptyMap() },
                        deviceId = deviceId,
                        deviceName = deviceName,
                        createdAt = event.createdAt,
                        isPinned = false,
                        isEncrypted = event.isEncrypted,
                        transportOrigin = event.transportOrigin
                    )
                    repository.upsert(item)
                }

                // Only broadcast if not a received item (prevent loops)
                // IMPORTANT: Broadcast even if item matched history - user may have re-copied it
                if (!event.skipBroadcast) {
                    // Wait up to 10 seconds for targets to be available (handles race condition with peer discovery)
                    var pairedDevices = _targets.value
                    if (pairedDevices.isEmpty()) {
                        val startTime = System.currentTimeMillis()
                        while (pairedDevices.isEmpty() && (System.currentTimeMillis() - startTime) < 10_000) {
                            kotlinx.coroutines.delay(100) // Check every 100ms
                            pairedDevices = _targets.value
                        }
                        if (pairedDevices.isEmpty()) {
                            Log.w(TAG, "⏭️  No paired devices available after waiting (targets: ${_targets.value})")
                        } else {
                            Log.i(TAG, "✅ Targets became available after ${System.currentTimeMillis() - startTime}ms: ${pairedDevices.size} devices")
                        }
                    }
                    
                    if (pairedDevices.isNotEmpty()) {
                        Log.i(TAG, "📤 Broadcasting to ${pairedDevices.size} paired devices: $pairedDevices")
                        pairedDevices.forEach { target ->
                            Log.i(TAG, "📤 Syncing to device: $target")
                            try {
                                val envelope = syncEngine.sendClipboard(item, target)
                                Log.i(TAG, "✅ Successfully sent clipboard to $target, envelope type: ${envelope.type}")
                            } catch (error: TransportPayloadTooLargeException) {
                                Log.w(TAG, "⚠️ Payload too large for $target, skipping sync: ${error.message}")
                                // Don't crash - just skip this sync
                            } catch (error: Exception) {
                                Log.e(TAG, "❌ Failed to sync to $target: ${error.message}", error)
                            }
                        }
                    } else {
                        Log.i(TAG, "⏭️  No paired devices to broadcast to (targets: ${_targets.value})")
                    }
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
        Log.d(TAG, "🎯 setTargetDevices called with: $deviceIds")
        manualTargets.value = deviceIds
        recomputeTargets()
        Log.d(TAG, "✅ Target devices updated: ${_targets.value}")
    }

    fun addTargetDevice(deviceId: String) {
        manualTargets.update { it + deviceId }
        // Refresh paired device IDs cache when adding a target (key should be saved by now)
        keyStoreScope.launch {
            try {
                val deviceIds = deviceKeyStore.getAllDeviceIds().toSet()
                pairedDeviceIdsCache.value = deviceIds
                recomputeTargets()
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Failed to refresh paired device IDs after adding target: ${e.message}")
                recomputeTargets() // Still recompute with current cache
            }
        }
        Log.i(TAG, "➕ Added manual sync target: $deviceId")
    }

    fun removeTargetDevice(deviceId: String) {
        manualTargets.update { it - deviceId }
        // Refresh paired device IDs cache when removing a target (key should be deleted by now)
        keyStoreScope.launch {
            try {
                val deviceIds = deviceKeyStore.getAllDeviceIds().toSet()
                pairedDeviceIdsCache.value = deviceIds
                recomputeTargets()
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Failed to refresh paired device IDs after removing target: ${e.message}")
                recomputeTargets() // Still recompute with current cache
            }
        }
        Log.i(TAG, "➖ Removed manual sync target: $deviceId")
    }

    companion object {
        private const val TAG = "SyncCoordinator"
    }
}
