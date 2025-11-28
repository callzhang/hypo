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
                transportManager.cloudConnectionState,  // Only show cloud server status in UI
                connectivityCheckTrigger.onStart { emit(Unit) } // Emit immediately on start
            ) { settings, peers, lastTransport, connectionState, _ ->
                val isAccessibilityEnabled = checkAccessibilityServiceStatus()
                // Load all paired devices directly from persistent storage
                val allPairedDeviceIds = runCatching { 
                    deviceKeyStore.getAllDeviceIds() 
                }.getOrElse { emptyList() }
                
                android.util.Log.d("SettingsViewModel", "📋 Found ${allPairedDeviceIds.size} paired devices: $allPairedDeviceIds")
                android.util.Log.d("SettingsViewModel", "📋 Discovered peers: ${peers.size}, lastTransport size: ${lastTransport.size}")
                
                // Build list of paired devices from storage (not synthetic peers)
                val pairedDevices = allPairedDeviceIds.mapNotNull { deviceId ->
                    val deviceName = transportManager.getDeviceName(deviceId)
                    if (deviceName != null) {
                        // Find discovered peer for this device (if any)
                        val discoveredPeer = peers.firstOrNull { peer ->
                            val peerDeviceId = peer.attributes["device_id"] ?: peer.serviceName
                            peerDeviceId == deviceId || peer.serviceName == deviceId
                        }
                        PairedDeviceInfo(
                            deviceId = deviceId,
                            deviceName = deviceName,
                            discoveredPeer = discoveredPeer
                        )
                    } else {
                        // Skip devices without stored name (they were deleted)
                        null
                    }
                }
                
                android.util.Log.d("SettingsViewModel", "📋 Built ${pairedDevices.size} paired devices from storage")
                
                // Convert paired devices to DiscoveredPeer for UI (since UI still expects DiscoveredPeer)
                // This is cleaner than "synthetic peers" - we're converting from storage to display format
                val pairedPeersForUi = pairedDevices.map { device ->
                    device.discoveredPeer ?: DiscoveredPeer(
                        serviceName = device.deviceName,
                        host = "unknown",
                        port = 0,
                        fingerprint = null,
                        attributes = mapOf("device_id" to device.deviceId, "device_name" to device.deviceName),
                        lastSeen = java.time.Instant.now()
                    )
                }
                
                // Map paired devices to include connection status and transport info
                val peerStatuses = pairedDevices.associate { device ->
                    val deviceId = device.deviceId
                    val serviceName = device.discoveredPeer?.serviceName ?: device.deviceName
                    val isDiscovered = device.discoveredPeer != null
                    
                    // Look up transport status using deviceId
                    val transport = lastTransport[deviceId]
                        ?: lastTransport.entries.firstOrNull { 
                            it.key.equals(deviceId, ignoreCase = true)
                        }?.value
                    
                    val isServerConnected = connectionState == com.hypo.clipboard.transport.ConnectionState.ConnectedCloud
                    val isServerIdle = connectionState == com.hypo.clipboard.transport.ConnectionState.Idle
                    
                    // Determine status: mark online if discovered on LAN or connected via cloud
                    val status = if (isServerIdle) {
                        DeviceConnectionStatus.Disconnected
                    } else when {
                        // Device is discovered on LAN AND has cloud transport AND server is connected → Connected via LAN and server
                        isDiscovered && transport == ActiveTransport.CLOUD && isServerConnected -> DeviceConnectionStatus.ConnectedLan
                        // Device is discovered on LAN → Connected via LAN
                        isDiscovered -> DeviceConnectionStatus.ConnectedLan
                        // Device has CLOUD transport AND server is connected → Connected via Cloud
                        transport == ActiveTransport.CLOUD && isServerConnected -> DeviceConnectionStatus.ConnectedCloud
                        // Device has CLOUD transport but server is offline → Disconnected
                        transport == ActiveTransport.CLOUD && !isServerConnected -> DeviceConnectionStatus.Disconnected
                        // Device is paired but not discovered and no transport record → Offline
                        else -> DeviceConnectionStatus.Disconnected
                    }
                    
                    serviceName to status
                }
                
                // Map peers to include transport info for address display
                val peerTransports = pairedDevices.associate { device ->
                    val deviceId = device.deviceId
                    val serviceName = device.discoveredPeer?.serviceName ?: device.deviceName
                    val transport = lastTransport[deviceId]
                        ?: lastTransport.entries.firstOrNull { 
                            it.key.equals(deviceId, ignoreCase = true)
                        }?.value
                    serviceName to transport
                }
                
                // Map peers to include device names (always use stored name)
                val peerDeviceNames = pairedDevices.associate { device ->
                    val serviceName = device.discoveredPeer?.serviceName ?: device.deviceName
                    serviceName to device.deviceName
                }
                
                // Map peers to include discovery status for connection info display
                val peerDiscoveryStatus = pairedDevices.associate { device ->
                    val serviceName = device.discoveredPeer?.serviceName ?: device.deviceName
                    serviceName to (device.discoveredPeer != null)
                }
                
                SettingsUiState(
                    lanSyncEnabled = settings.lanSyncEnabled,
                    historyLimit = settings.historyLimit,
                    autoDeleteDays = settings.autoDeleteDays,
                    plainTextModeEnabled = settings.plainTextModeEnabled,
                    discoveredPeers = pairedPeersForUi,
                    deviceStatuses = peerStatuses,
                    deviceTransports = peerTransports,
                    isAccessibilityServiceEnabled = isAccessibilityEnabled,
                    connectionState = connectionState,
                    peerDiscoveryStatus = peerDiscoveryStatus,
                    peerDeviceNames = peerDeviceNames
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
            // Delete the encryption key FIRST (this removes it from getAllDeviceIds())
            runCatching { 
                deviceKeyStore.deleteKey(deviceId)
                android.util.Log.d("SettingsViewModel", "🔑 Deleted encryption key for device: $deviceId")
            }
            // Then forget the paired device (clears transport status and device name)
            transportManager.forgetPairedDevice(deviceId)
            syncCoordinator.removeTargetDevice(deviceId)
            android.util.Log.d("SettingsViewModel", "✅ Device removed: $deviceId")
        }
    }
    
    // Internal data class for paired device info
    private data class PairedDeviceInfo(
        val deviceId: String,
        val deviceName: String,
        val discoveredPeer: DiscoveredPeer? // null if not currently discovered on LAN
    )
    
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
        val historyLimit: Int = UserSettings.DEFAULT_HISTORY_LIMIT,
        val autoDeleteDays: Int = UserSettings.DEFAULT_AUTO_DELETE_DAYS,
        val plainTextModeEnabled: Boolean = false,
        val discoveredPeers: List<DiscoveredPeer> = emptyList(),
        val deviceStatuses: Map<String, DeviceConnectionStatus> = emptyMap(),
        val deviceTransports: Map<String, ActiveTransport?> = emptyMap(),
        val isAccessibilityServiceEnabled: Boolean = false,
        val connectionState: com.hypo.clipboard.transport.ConnectionState = com.hypo.clipboard.transport.ConnectionState.Idle,
        val peerDiscoveryStatus: Map<String, Boolean> = emptyMap(), // Maps serviceName to isDiscovered
        val peerDeviceNames: Map<String, String?> = emptyMap() // Maps serviceName to device name
    )
