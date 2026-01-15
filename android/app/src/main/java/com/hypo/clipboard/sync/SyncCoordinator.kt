package com.hypo.clipboard.sync

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import dagger.hilt.android.qualifiers.ApplicationContext
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
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.util.Base64
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
    private val lanTransportClient: com.hypo.clipboard.transport.ws.WebSocketTransportClient,
    @ApplicationContext private val context: Context
) {
    private var eventChannel: Channel<ClipboardEvent>? = null
    private var job: Job? = null
    private val autoTargets = MutableStateFlow<Set<String>>(emptySet())
    private val manualTargets = MutableStateFlow<Set<String>>(emptySet())
    private val _targets = MutableStateFlow<Set<String>>(emptySet())
    val targets: StateFlow<Set<String>> = _targets.asStateFlow()
    private val keyStoreJob = SupervisorJob()
    private val keyStoreScope = CoroutineScope(keyStoreJob + Dispatchers.Default)
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
                
                // Note: Connection establishment is now handled by LanPeerConnectionManager (LPM)
                // which automatically connects to all discovered peers.
                // We don't need to manually start a receiving loop here anymore.
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
        Log.v(TAG, "🎯 Recomputed targets: auto=${autoTargets.value.size}, manual=${manualTargets.value.size}, candidates=${allCandidates.size}, paired=${pairedDeviceIds.size}, allPairedTargets=${allPairedTargets.size}, discoveredAndPaired=${discoveredAndPaired.size}, filtered=${filtered.size}, localDeviceId=${identity.deviceId}")
        
        if (filtered.size < allCandidates.size) {
            val missing = allCandidates - filtered
            Log.v(TAG, "⚠️ Excluded ${missing.size} devices without keys: $missing")
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
                // Use device info if available (from remote sync), otherwise use local device info
                // Normalize to lowercase for consistent matching
                val deviceId = (event.deviceId ?: identity.deviceId).lowercase()
                val deviceName = event.deviceName ?: identity.deviceName
                
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
                    transportOrigin = event.transportOrigin,
                    localPath = event.localPath
                )
                
                val latestEntry = repository.getLatestEntry()
                
                // Check if matches current clipboard (latest entry)
                val matchesCurrentClipboard = latestEntry?.let { latest ->
                    val matches = eventItem.matchesContent(latest)
                    android.util.Log.v(TAG, "🔍 Checking match with latest entry: eventType=${eventItem.type}, latestType=${latest.type}, matches=$matches")
                    if (eventItem.type == ClipboardType.IMAGE || eventItem.type == ClipboardType.FILE) {
                        val eventHash = eventItem.metadata?.get("hash")
                        val latestHash = latest.metadata?.get("hash")
                        android.util.Log.v(TAG, "🔍 Hash comparison: eventHash=${eventHash?.take(16)}, latestHash=${latestHash?.take(16)}, hashMatch=${eventHash == latestHash}")
                    }
                    matches
                } ?: false
                
                val item: ClipboardItem = if (matchesCurrentClipboard && latestEntry != null) {
                    // Remove old item and create new one at top (ensures it's definitely at top)
                    android.util.Log.v(TAG, "🔄 Matched current clipboard, removing old item and creating new one at top: id=${latestEntry.id}")
                    try {
                        repository.delete(latestEntry.id)
                        
                        // Preserve origin info if this is a local event (event.deviceId == null)
                        val isLocalEvent = event.deviceId == null
                        val resolvedDeviceId = if (isLocalEvent) latestEntry.deviceId ?: deviceId else deviceId
                        val resolvedDeviceName = if (isLocalEvent) latestEntry.deviceName ?: deviceName else deviceName
                        val resolvedTransportOrigin = if (isLocalEvent) latestEntry.transportOrigin else event.transportOrigin
                        
                        // Create new item with current timestamp (will be at top)
                        val newItem = ClipboardItem(
                            id = event.id,
                            type = event.type,
                            content = event.content, // Use new content (same but fresh)
                            preview = event.preview,
                            metadata = event.metadata.ifEmpty { emptyMap() },
                            deviceId = resolvedDeviceId,
                            deviceName = resolvedDeviceName,
                            createdAt = Instant.now(),
                            isPinned = latestEntry.isPinned, // Preserve pinned state
                            isEncrypted = latestEntry.isEncrypted, // Preserve encryption state
                            transportOrigin = resolvedTransportOrigin,
                            localPath = latestEntry.localPath ?: event.localPath // Prefer existing path if valid
                        )
                        repository.upsert(newItem)
                        android.util.Log.d(TAG, "✅ Successfully removed old item and created new one at top: ${newItem.preview.take(50)}")
                        newItem
                    } catch (e: Exception) {
                        android.util.Log.e(TAG, "❌ Error removing/creating item: ${e.message}. Duplicate detection will not move item to top.", e)
                        // Continue with existing item - duplicate detection failed but item exists
                        latestEntry
                    }
                } else {
                    // Check if matches something in history (excluding the latest entry)
                    android.util.Log.v(TAG, "🔍 Checking for match in history (excluding latest entry)")
                    val matchingEntry = try {
                        repository.findMatchingEntryInHistory(eventItem)
                    } catch (e: Exception) {
                        android.util.Log.e(TAG, "❌ Error finding matching entry in history: ${e.message}", e)
                        null // Continue as if no match found
                    }
                    
                    if (matchingEntry != null) {
                        // Found matching entry in history - remove old item and create new one at top
                        android.util.Log.v(TAG, "🔄 Matched history item, removing old item and creating new one at top: id=${matchingEntry.id}")
                        try {
                            repository.delete(matchingEntry.id)
                            
                            // Preserve origin info if this is a local event (event.deviceId == null)
                            val isLocalEvent = event.deviceId == null
                            val resolvedDeviceId = if (isLocalEvent) matchingEntry.deviceId ?: deviceId else deviceId
                            val resolvedDeviceName = if (isLocalEvent) matchingEntry.deviceName ?: deviceName else deviceName
                            val resolvedTransportOrigin = if (isLocalEvent) matchingEntry.transportOrigin else event.transportOrigin
                            
                            // Create new item with current timestamp (will be at top)
                            val newItem = ClipboardItem(
                                id = event.id,
                                type = event.type,
                                content = event.content,
                                preview = event.preview,
                                metadata = event.metadata.ifEmpty { emptyMap() },
                                deviceId = resolvedDeviceId,
                                deviceName = resolvedDeviceName,
                                createdAt = Instant.now(),
                                isPinned = matchingEntry.isPinned, // Preserve pinned state
                                isEncrypted = matchingEntry.isEncrypted, // Preserve encryption state
                                transportOrigin = resolvedTransportOrigin,
                                localPath = matchingEntry.localPath ?: event.localPath // Prefer existing path if valid
                            )
                            repository.upsert(newItem)
                            android.util.Log.d(TAG, "✅ Successfully removed old history item and created new one at top: ${newItem.preview.take(50)}")
                            newItem
                        } catch (e: Exception) {
                            android.util.Log.e(TAG, "❌ Error removing/creating history item: ${e.message}. Duplicate detection will not move item to top.", e)
                            // Continue with existing item - duplicate detection failed but item exists
                            matchingEntry
                        }
                    } else {
                        // Not a duplicate - add to history
                        val newItem = ClipboardItem(
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
                            transportOrigin = event.transportOrigin,
                            localPath = event.localPath
                        )
                        try {
                            repository.upsert(newItem)
                        } catch (e: android.database.sqlite.SQLiteBlobTooBigException) {
                            android.util.Log.e(TAG, "❌ SQLiteBlobTooBigException when saving ${event.type} item: ${e.message}. Item too large to save.", e)
                            // Skip this item - it's too large to save
                            continue
                        } catch (e: Exception) {
                            android.util.Log.e(TAG, "❌ Error upserting item to database: ${e.message}", e)
                            // Continue anyway - don't crash the whole sync process
                        }
                        newItem
                    }
                }

                // Note: We don't update system clipboard here because:
                // 1. The item is already saved to database (above)
                // 2. UI will update from database automatically
                // 3. Notification already shows the latest content
                // 4. Updating clipboard would trigger ClipboardListener.onPrimaryClipChanged(),
                //    which could cause loops or overwrite the database entry
                // If background clipboard update is needed, use Accessibility Service (see settings)

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
                            Log.d(TAG, "✅ Targets became available after ${System.currentTimeMillis() - startTime}ms: ${pairedDevices.size} devices")
                        }
                    }
                    
                    if (pairedDevices.isNotEmpty()) {
                        val results = mutableListOf<String>()
                        pairedDevices.forEach { target ->
                            try {
                                syncEngine.sendClipboard(item, target)
                                results.add("✅ $target")
                            } catch (error: TransportPayloadTooLargeException) {
                                results.add("⚠️ $target (too large)")
                                // Don't crash - just skip this sync
                            } catch (error: Exception) {
                                results.add("❌ $target (${error.message?.take(30)})")
                            }
                        }
                        Log.v(TAG, "📤 Sync: ${pairedDevices.size} device(s) → ${results.joinToString(", ")}")
                    } else {
                        Log.d(TAG, "⏭️ Sync: No paired devices (targets: ${_targets.value})")
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
        keyStoreJob.cancel()
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
        // IMPORTANT: Launch coroutine but also immediately refresh cache synchronously to avoid race condition
        // where LanPairingViewModel checks targets.value before the coroutine completes
        keyStoreScope.launch {
            try {
                val deviceIds = deviceKeyStore.getAllDeviceIds().toSet()
                pairedDeviceIdsCache.value = deviceIds
                Log.d(TAG, "🔄 Refreshed paired device IDs cache: ${deviceIds.size} devices")
                recomputeTargets()
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Failed to refresh paired device IDs after adding target: ${e.message}")
                recomputeTargets() // Still recompute with current cache
            }
        }
        Log.d(TAG, "➕ Added manual sync target: $deviceId")
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
        Log.d(TAG, "➖ Removed manual sync target: $deviceId")
    }

    companion object {
        private const val TAG = "SyncCoordinator"
    }
}
