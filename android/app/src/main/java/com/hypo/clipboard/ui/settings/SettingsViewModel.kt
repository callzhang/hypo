package com.hypo.clipboard.ui.settings

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.view.accessibility.AccessibilityManager
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.service.ClipboardAccessibilityService
import com.hypo.clipboard.transport.ActiveTransport
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import com.hypo.clipboard.ui.components.DeviceConnectionStatus
import com.hypo.clipboard.sync.SyncCoordinator
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
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
    private val syncCoordinator: SyncCoordinator,
    @ApplicationContext private val context: Context
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
    
    // Flow that emits accessibility service status
    private val accessibilityStatusFlow = flow {
        while (true) {
            delay(2_000L) // Check every 2 seconds
            emit(checkAccessibilityServiceStatus())
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
                transportManager.connectionState,
                connectivityCheckTrigger.onStart { emit(Unit) } // Emit immediately on start
            ) { settings, peers, lastTransport, connectionState, _ ->
                val isAccessibilityEnabled = checkAccessibilityServiceStatus()
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
                    
                    // Determine status: 
                    // - LAN devices must be discovered AND have transport status to show as Connected
                    // - CLOUD devices can show as Connected if they have transport status (don't require discovery)
                    // - Paired devices without transport record are "Paired" (will use LAN-first, cloud-fallback on sync)
                    val status = when {
                        // Device is discovered AND has LAN transport → Connected via LAN
                        // This works even if device changed network (matched by device_id, not IP)
                        isDiscovered && transport == ActiveTransport.LAN -> DeviceConnectionStatus.ConnectedLan
                        // Device has CLOUD transport → Connected via Cloud (don't require discovery)
                        transport == ActiveTransport.CLOUD -> DeviceConnectionStatus.ConnectedCloud
                        // Device is discovered but no transport record → Disconnected (connection not established yet)
                        isDiscovered -> DeviceConnectionStatus.Disconnected
                        // Device is paired but not discovered and no transport record → Paired (will use LAN-first, cloud-fallback)
                        // Code-paired devices may not have transport marked yet - they'll try LAN first, then cloud on sync
                        else -> DeviceConnectionStatus.Paired
                    }
                    android.util.Log.d("SettingsViewModel", "📊 Final status for $deviceId: $status (isDiscovered=$isDiscovered, transport=$transport)")
                    serviceName to status
                }
                
                SettingsUiState(
                    lanSyncEnabled = settings.lanSyncEnabled,
                    cloudSyncEnabled = settings.cloudSyncEnabled,
                    historyLimit = settings.historyLimit,
                    autoDeleteDays = settings.autoDeleteDays,
                    plainTextModeEnabled = settings.plainTextModeEnabled,
                    discoveredPeers = pairedPeers,
                    deviceStatuses = peerStatuses,
                    isAccessibilityServiceEnabled = isAccessibilityEnabled,
                    connectionState = connectionState
                )
            }.collect { state ->
                _state.value = state
            }
            
            // Also observe accessibility status separately to update it periodically
            accessibilityStatusFlow.collect { isEnabled ->
                _state.value = _state.value.copy(isAccessibilityServiceEnabled = isEnabled)
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

    fun onPlainTextModeChanged(enabled: Boolean) {
        viewModelScope.launch { settingsRepository.setPlainTextModeEnabled(enabled) }
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
    
    private fun checkAccessibilityServiceStatus(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return true // Not needed on older Android versions
        }
        
        val accessibilityManager = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager ?: return false
        val enabledServices = accessibilityManager.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
        val serviceClassName = ClipboardAccessibilityService::class.java.name
        val serviceName = ComponentName(context.packageName, serviceClassName)
        
        // Check if our accessibility service is enabled
        return enabledServices.any { serviceInfo ->
            val componentName = ComponentName(
                serviceInfo.resolveInfo.serviceInfo.packageName,
                serviceInfo.resolveInfo.serviceInfo.name
            )
            componentName == serviceName || serviceInfo.resolveInfo.serviceInfo.name == serviceClassName
        }
    }
}

data class SettingsUiState(
    val lanSyncEnabled: Boolean = true,
    val cloudSyncEnabled: Boolean = true,
    val historyLimit: Int = UserSettings.DEFAULT_HISTORY_LIMIT,
    val autoDeleteDays: Int = UserSettings.DEFAULT_AUTO_DELETE_DAYS,
    val plainTextModeEnabled: Boolean = false,
    val discoveredPeers: List<DiscoveredPeer> = emptyList(),
    val deviceStatuses: Map<String, DeviceConnectionStatus> = emptyMap(),
    val isAccessibilityServiceEnabled: Boolean = false,
    val connectionState: com.hypo.clipboard.transport.ConnectionState = com.hypo.clipboard.transport.ConnectionState.Idle
)
