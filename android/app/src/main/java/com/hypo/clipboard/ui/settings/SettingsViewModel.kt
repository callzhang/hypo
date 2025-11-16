package com.hypo.clipboard.ui.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.transport.ActiveTransport
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import com.hypo.clipboard.ui.components.DeviceConnectionStatus
import com.hypo.clipboard.sync.SyncCoordinator
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.launch

@HiltViewModel
class SettingsViewModel @Inject constructor(
    private val settingsRepository: SettingsRepository,
    private val transportManager: TransportManager,
    private val deviceKeyStore: com.hypo.clipboard.sync.DeviceKeyStore,
    private val lanWebSocketClient: com.hypo.clipboard.transport.ws.LanWebSocketClient,
    private val syncCoordinator: SyncCoordinator
) : ViewModel() {

    private val _state = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = _state.asStateFlow()
    
    // Flow that emits periodically to trigger connectivity checks
    private val connectivityCheckTrigger = flow {
        while (true) {
            delay(5_000L) // Check every 5 seconds
            emit(Unit)
        }
    }

    init {
        observeState()
    }

    private fun observeState() {
        viewModelScope.launch {
            combine(
                settingsRepository.settings,
                transportManager.peers,
                transportManager.lastSuccessfulTransport,
                connectivityCheckTrigger.onStart { emit(Unit) } // Emit immediately on start
            ) { settings, peers, lastTransport, _ ->
                // Get ALL paired device IDs from DeviceKeyStore (not just discovered ones)
                val allPairedDeviceIds = runCatching { 
                    deviceKeyStore.getAllDeviceIds() 
                }.getOrElse { emptyList() }
                
                android.util.Log.d("SettingsViewModel", "📋 Found ${allPairedDeviceIds.size} paired devices: $allPairedDeviceIds")
                android.util.Log.d("SettingsViewModel", "📋 Discovered peers: ${peers.size}, lastTransport size: ${lastTransport.size}, keys: ${lastTransport.keys}")
                
                // Debug: Log the full lastTransport map
                if (lastTransport.isNotEmpty()) {
                    android.util.Log.d("SettingsViewModel", "📋 lastTransport contents: $lastTransport")
                } else {
                    android.util.Log.w("SettingsViewModel", "⚠️ lastTransport is empty! This should not happen if status was persisted.")
                }
                
                // Build a map of paired peers: discovered peers + synthetic peers for paired but not discovered devices
                val pairedPeersMap = mutableMapOf<String, DiscoveredPeer>()
                
                // First, add all discovered peers that are paired
                // Note: Devices are matched by device_id (UUID) which is stable across network changes
                // When a device changes network (different IP), it will be re-discovered with the same device_id
                for (peer in peers) {
                    val deviceId = peer.attributes["device_id"] ?: peer.serviceName
                    // Match by device_id (preferred) or serviceName (fallback for legacy devices)
                    if (allPairedDeviceIds.contains(deviceId) || allPairedDeviceIds.contains(peer.serviceName)) {
                        // Use deviceId as key to ensure consistent matching even if serviceName changes
                        pairedPeersMap[deviceId] = peer
                        android.util.Log.d("SettingsViewModel", "✅ Found discovered paired device: deviceId=$deviceId, serviceName=${peer.serviceName}, host=${peer.host}")
                    }
                }
                
                // Then, create synthetic peers for paired devices that are not currently discovered
                for (deviceId in allPairedDeviceIds) {
                    if (!pairedPeersMap.containsKey(deviceId)) {
                        // Get stored device name, fallback to deviceId if not found
                        val deviceName = transportManager.getDeviceName(deviceId) ?: deviceId
                        // Create a synthetic peer for this paired but not discovered device
                        val syntheticPeer = DiscoveredPeer(
                            serviceName = deviceName, // Use stored device name for display
                            host = "unknown",
                            port = 0,
                            fingerprint = null,
                            attributes = mapOf("device_id" to deviceId, "device_name" to deviceName),
                            lastSeen = java.time.Instant.now()
                        )
                        pairedPeersMap[deviceId] = syntheticPeer
                        android.util.Log.d("SettingsViewModel", "📦 Created synthetic peer for paired but not discovered device: $deviceId (name=$deviceName)")
                    }
                }
                
                val pairedPeers = pairedPeersMap.values.toList()
                
                // Map peers to include connection status
                val peerStatuses = pairedPeers.associate { peer ->
                    val deviceId = peer.attributes["device_id"] ?: peer.serviceName
                    val serviceName = peer.serviceName
                    
                    // Look up transport status using the deviceId (this is what was saved during pairing)
                    // Try exact match first (case-sensitive), then case-insensitive, then fuzzy matching
                    val transport = lastTransport[deviceId]
                        ?: lastTransport[serviceName]
                        ?: lastTransport.entries.firstOrNull { 
                            it.key.equals(deviceId, ignoreCase = true)
                        }?.value
                        ?: lastTransport.entries.firstOrNull { 
                            it.key.equals(serviceName, ignoreCase = true)
                        }?.value
                        ?: lastTransport.entries.firstOrNull { 
                            // Try fuzzy matching for device IDs (UUIDs might have different case)
                            val key = it.key
                            key.equals(deviceId, ignoreCase = true) || 
                            key.equals(serviceName, ignoreCase = true) ||
                            key.replace("-", "").equals(deviceId.replace("-", ""), ignoreCase = true) ||
                            key.replace("-", "").equals(serviceName.replace("-", ""), ignoreCase = true)
                        }?.value
                    
                    val isDiscovered = peers.any { 
                        val peerDeviceId = it.attributes["device_id"] ?: it.serviceName
                        peerDeviceId == deviceId || it.serviceName == serviceName
                    }
                    
                    android.util.Log.d("SettingsViewModel", "🔍 Status check: deviceId=$deviceId, serviceName=$serviceName, transport=$transport, isDiscovered=$isDiscovered, lastTransport keys=${lastTransport.keys}")
                    
                    // Determine status: device must be discovered AND have transport status to show as Connected
                    // If device is not discovered (macOS app closed or different network), show as Disconnected
                    // Note: When device changes network, it will be re-discovered with same device_id and status will update
                    val status = when {
                        // Device is discovered AND has a transport record → Connected
                        // This works even if device changed network (matched by device_id, not IP)
                        isDiscovered && transport == ActiveTransport.LAN -> DeviceConnectionStatus.ConnectedLan
                        isDiscovered && transport == ActiveTransport.CLOUD -> DeviceConnectionStatus.ConnectedCloud
                        // Device is discovered but no transport record → Disconnected (connection not established yet)
                        isDiscovered -> DeviceConnectionStatus.Disconnected
                        // Device is paired but not on network (macOS app quit, different network, or unreachable) → Disconnected
                        // Note: Cloud connectivity is handled via fallback during sync, not device discovery
                        else -> DeviceConnectionStatus.Disconnected
                    }
                    android.util.Log.d("SettingsViewModel", "📊 Final status for $deviceId: $status (isDiscovered=$isDiscovered, transport=$transport)")
                    serviceName to status
                }
                
                SettingsUiState(
                    lanSyncEnabled = settings.lanSyncEnabled,
                    cloudSyncEnabled = settings.cloudSyncEnabled,
                    historyLimit = settings.historyLimit,
                    autoDeleteDays = settings.autoDeleteDays,
                    discoveredPeers = pairedPeers,
                    deviceStatuses = peerStatuses
                )
            }.collect { state ->
                _state.value = state
            }
        }
    }

    fun onLanSyncChanged(enabled: Boolean) {
        viewModelScope.launch { settingsRepository.setLanSyncEnabled(enabled) }
    }

    fun onCloudSyncChanged(enabled: Boolean) {
        viewModelScope.launch { settingsRepository.setCloudSyncEnabled(enabled) }
    }

    fun onHistoryLimitChanged(limit: Int) {
        viewModelScope.launch { settingsRepository.setHistoryLimit(limit) }
    }

    fun onAutoDeleteDaysChanged(days: Int) {
        viewModelScope.launch { settingsRepository.setAutoDeleteDays(days) }
    }
    
    fun removeDevice(peer: DiscoveredPeer) {
        viewModelScope.launch {
            val deviceId = peer.attributes["device_id"] ?: peer.serviceName
            android.util.Log.d("SettingsViewModel", "🗑️ Removing device: deviceId=$deviceId, serviceName=${peer.serviceName}")
            // Remove from transport manager (only if it's a discovered peer)
            if (peer.host != "unknown") {
                transportManager.removePeer(peer.serviceName)
            }
            // Forget the paired device (clears transport status and device name)
            transportManager.forgetPairedDevice(deviceId)
            syncCoordinator.removeTargetDevice(deviceId)
            // Delete the encryption key
            runCatching { deviceKeyStore.deleteKey(deviceId) }
            android.util.Log.d("SettingsViewModel", "✅ Device removed: $deviceId")
        }
    }
}

data class SettingsUiState(
    val lanSyncEnabled: Boolean = true,
    val cloudSyncEnabled: Boolean = true,
    val historyLimit: Int = UserSettings.DEFAULT_HISTORY_LIMIT,
    val autoDeleteDays: Int = UserSettings.DEFAULT_AUTO_DELETE_DAYS,
    val discoveredPeers: List<DiscoveredPeer> = emptyList(),
    val deviceStatuses: Map<String, DeviceConnectionStatus> = emptyMap()
)
