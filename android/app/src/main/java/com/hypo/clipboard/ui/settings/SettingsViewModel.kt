package com.hypo.clipboard.ui.settings

import android.Manifest
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.view.accessibility.AccessibilityManager
import androidx.core.content.ContextCompat
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
    private val lanWebSocketClient: com.hypo.clipboard.transport.ws.WebSocketTransportClient,
    private val syncCoordinator: SyncCoordinator,
    @ApplicationContext private val context: Context
) : ViewModel() {

    private val _state = MutableStateFlow(SettingsUiState())
    val state: StateFlow<SettingsUiState> = _state.asStateFlow()
    
    // Flow that emits accessibility service status periodically (needed for UI updates)
    private val accessibilityStatusFlow = flow {
        while (true) {
            delay(2_000L) // Check every 2 seconds
            emit(checkAccessibilityServiceStatus())
        }
    }
    
    // Flow that emits SMS permission status periodically (needed for UI updates)
    private val smsPermissionStatusFlow = flow {
        while (true) {
            delay(2_000L) // Check every 2 seconds
            emit(checkSmsPermissionStatus())
        }
    }
    
    // Flow that emits notification permission status periodically (needed for UI updates)
    private val notificationPermissionStatusFlow = flow {
        while (true) {
            delay(2_000L) // Check every 2 seconds
            emit(checkNotificationPermissionStatus())
        }
    }
    
    // Flow that emits battery optimization status periodically (needed for UI updates)
    private val batteryOptimizationStatusFlow = flow {
        while (true) {
            delay(2_000L) // Check every 2 seconds
            emit(checkBatteryOptimizationStatus())
        }
    }

    init {
        observeState()
    }

    private fun observeState() {
        viewModelScope.launch {
            // Event-driven: UI updates automatically when any of these flows emit
            // The accessibilityStatusFlow and smsPermissionStatusFlow are already included in combine,
            // so they will emit every 2 seconds and trigger UI updates automatically.
            // No need for separate collectors - they would never execute anyway since collect() suspends indefinitely.
            combine(
                settingsRepository.settings,
                transportManager.peers,  // Emits when peers are discovered/lost
                transportManager.lastSuccessfulTransport,  // Emits when transport status changes
                transportManager.cloudConnectionState,  // Cloud-only connection state - tracks cloud state separately from LAN
                accessibilityStatusFlow.onStart { emit(checkAccessibilityServiceStatus()) }, // Emit immediately on start, then every 2 seconds
                smsPermissionStatusFlow.onStart { emit(checkSmsPermissionStatus()) }, // Emit immediately on start, then every 2 seconds
                notificationPermissionStatusFlow.onStart { emit(checkNotificationPermissionStatus()) }, // Emit immediately on start, then every 2 seconds
                batteryOptimizationStatusFlow.onStart { emit(checkBatteryOptimizationStatus()) } // Emit immediately on start, then every 2 seconds
            ) { values ->
                val settings = values[0] as UserSettings
                val peers = values[1] as List<DiscoveredPeer>
                val lastTransport = values[2] as Map<String, com.hypo.clipboard.transport.ActiveTransport>
                val cloudConnectionState = values[3] as com.hypo.clipboard.transport.ConnectionState
                val isAccessibilityEnabled = values[4] as Boolean
                val isSmsPermissionGranted = values[5] as Boolean
                val isNotificationPermissionGranted = values[6] as Boolean
                val isBatteryOptimizationDisabled = values[7] as Boolean
                // Load all paired devices directly from persistent storage
                val allPairedDeviceIds = runCatching { 
                    deviceKeyStore.getAllDeviceIds() 
                }.getOrElse { emptyList() }
                
                // Build list of paired devices from storage (not synthetic peers)
                val pairedDevices = allPairedDeviceIds.mapNotNull { deviceId ->
                    val deviceName = transportManager.getDeviceName(deviceId)
                    if (deviceName != null) {
                        // Find discovered peer for this device (if any) - use case-insensitive matching
                        val normalizedDeviceId = deviceId.lowercase()
                        val discoveredPeer = peers.firstOrNull { peer ->
                            val peerDeviceId = peer.attributes["device_id"] ?: peer.serviceName
                            peerDeviceId.lowercase() == normalizedDeviceId || 
                            peer.serviceName.lowercase() == normalizedDeviceId ||
                            peerDeviceId == deviceId || 
                            peer.serviceName == deviceId
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
                    
                    val isServerConnected = cloudConnectionState == com.hypo.clipboard.transport.ConnectionState.ConnectedCloud
                    
                    // Determine status: prioritize discovery status since LAN connections are on-demand
                    val status = when {
                        // Device is discovered on LAN → Connected via LAN (regardless of global connection state)
                        // LAN connections are established on-demand, so discovery means the device is reachable
                        isDiscovered -> DeviceConnectionStatus.ConnectedLan
                        // Device has LAN transport → Connected via LAN (even if not currently discovered)
                        transport == ActiveTransport.LAN -> DeviceConnectionStatus.ConnectedLan
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
                        ?: lastTransport.entries.firstOrNull { entry ->
                            entry.key.equals(deviceId, ignoreCase = true)
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
                    isSmsPermissionGranted = isSmsPermissionGranted,
                    isNotificationPermissionGranted = isNotificationPermissionGranted,
                    isBatteryOptimizationDisabled = isBatteryOptimizationDisabled,
                    connectionState = cloudConnectionState,
                    peerDiscoveryStatus = peerDiscoveryStatus,
                    peerDeviceNames = peerDeviceNames
                )
            }.collect { state ->
                _state.value = state
            }
            // Note: The separate collectors for accessibilityStatusFlow and smsPermissionStatusFlow
            // were removed because they would never execute (collect() above suspends indefinitely).
            // The flows are already included in the combine() above, so they will emit every 2 seconds
            // and trigger UI updates automatically through the combine collector.
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
    
    private fun checkSmsPermissionStatus(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true // Permission granted by default on older Android versions
        }
        return ContextCompat.checkSelfPermission(context, Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED
    }
    
    private fun checkNotificationPermissionStatus(): Boolean {
        // Notification permission is only required on Android 13+ (API 33+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        }
        // On older versions, notifications are always allowed
        return true
    }
    
    private fun checkBatteryOptimizationStatus(): Boolean {
        return com.hypo.clipboard.util.MiuiAdapter.isBatteryOptimizationDisabled(context)
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
        val isSmsPermissionGranted: Boolean = false,
        val isNotificationPermissionGranted: Boolean = false,
        val isBatteryOptimizationDisabled: Boolean = false,
        val connectionState: com.hypo.clipboard.transport.ConnectionState = com.hypo.clipboard.transport.ConnectionState.Disconnected,
        val peerDiscoveryStatus: Map<String, Boolean> = emptyMap(), // Maps serviceName to isDiscovered
        val peerDeviceNames: Map<String, String?> = emptyMap() // Maps serviceName to device name
    )
