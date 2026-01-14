package com.hypo.clipboard.transport

import android.util.Log
import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.sync.DeviceKeyStore
import com.hypo.clipboard.transport.ws.WebSocketTransportClient
import com.hypo.clipboard.transport.ws.RelayWebSocketClient
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import java.time.Duration
import java.net.HttpURLConnection
import java.net.URL
import javax.inject.Inject
import javax.inject.Named
import javax.inject.Singleton

/**
 * Periodically probes connection status to paired devices and updates their online status.
 * Checks on app launch, when app comes to foreground, and every 1 minute.
 */
@Singleton
class ConnectionStatusProber @Inject constructor(
    private val transportManager: TransportManager,
    private val settingsRepository: SettingsRepository,
    private val deviceKeyStore: DeviceKeyStore,
    private val lanWebSocketClient: WebSocketTransportClient,
    private val cloudWebSocketClient: RelayWebSocketClient,
    @Named("cloud_ws_config") private val cloudConfig: com.hypo.clipboard.transport.ws.TlsWebSocketConfig
) {
    private val scope = CoroutineScope(SupervisorJob())
    private var peersObserverJob: Job? = null
    private var cloudStateObserverJob: Job? = null
    private var safetyTimerJob: Job? = null
    private var periodicCheckJob: Job? = null
    private var isProbing = false
    
    // Store dual status for each device (deviceId -> DeviceDualStatus)
    private val _deviceDualStatus = MutableStateFlow<Map<String, com.hypo.clipboard.ui.components.DeviceDualStatus>>(emptyMap())
    val deviceDualStatus: StateFlow<Map<String, com.hypo.clipboard.ui.components.DeviceDualStatus>> = _deviceDualStatus.asStateFlow()
    
    companion object {
        private const val TAG = "ConnectionStatusProber"
        // Safety timer interval for belt-and-suspenders (debugging builds) or as fallback
        // Only used if event-driven observation fails
        private val SAFETY_TIMER_INTERVAL_MS = Duration.ofMinutes(5).toMillis() // 5 minutes - safety net
        // Periodic check interval for actively querying peer status via cloud
        private val PERIODIC_CHECK_INTERVAL_MS = Duration.ofMinutes(10).toMillis() // 10 minutes
        // Debounce delay to avoid spamming probeConnections() on rapid state changes
        private val DEBOUNCE_DELAY_MS = 500L // 500ms debounce
    }
    
    /**
     * Start event-driven connection status probing.
     * Observes StateFlows for peers and cloud connection state changes,
     * with a safety timer as fallback.
     */
    fun start() {
        stop() // Stop any existing jobs
        
        // Initial probe on launch
        scope.launch {
            probeConnections()
        }
        
        // Peer discovery no longer drives LAN online status (WS connection only)
        
        // Event-driven: observe cloud connection state changes
        // StateFlow already deduplicates, so we only need debounce to avoid rapid-fire probes
        cloudStateObserverJob = scope.launch {
            cloudWebSocketClient.connectionState
                .debounce(DEBOUNCE_DELAY_MS)
                .collect { state ->
                    Log.d(TAG, "☁️ Cloud connection state changed: $state, triggering probe")
                    probeConnections()
                }
        }
        
        // Safety timer: belt-and-suspenders for debugging builds or as fallback
        // Only runs if event-driven observation fails
        safetyTimerJob = scope.launch {
            while (isActive) {
                delay(SAFETY_TIMER_INTERVAL_MS)
                if (isActive) {
                    Log.d(TAG, "⏰ Safety timer triggered probe (fallback)")
                    probeConnections()
                }
            }
        }
        
        // Periodic check: actively query peer status via cloud every 10 minutes
        periodicCheckJob = scope.launch {
            while (isActive) {
                delay(PERIODIC_CHECK_INTERVAL_MS)
                if (isActive) {
                    Log.d(TAG, "⏰ Periodic check triggered - querying cloud for connected peers")
                    probeConnections()
                }
            }
        }
        
        // Event-driven: trigger probe when LAN connections change (connect/disconnect)
        // Add delay when LAN connects to give peer time to establish cloud connection too
        transportManager.setLanConnectionChangeListener {
            Log.d(TAG, "🔌 LAN connection changed - triggering probe after 3 second delay")
            scope.launch {
                // Give peer 3 seconds to complete cloud connection (typical startup race)
                delay(3000)
                probeConnections()
            }
        }
    }
    
    /**
     * Stop event-driven probing
     */
    fun stop() {
        peersObserverJob?.cancel()
        peersObserverJob = null
        cloudStateObserverJob?.cancel()
        cloudStateObserverJob = null
        safetyTimerJob?.cancel()
        safetyTimerJob = null
        periodicCheckJob?.cancel()
        periodicCheckJob = null
    }
    
    /**
     * Probe connections immediately (called when app comes to foreground)
     */
    fun probeNow() {
        scope.launch {
            probeConnections()
        }
    }
    
    /**
     * Cleanup resources
     */
    fun cleanup() {
        stop()
        scope.cancel()
    }
    
    /**
     * Check network connectivity first, then server health
     */
    private suspend fun checkNetworkConnectivity(): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                // Quick connectivity check - try to resolve a well-known DNS
                val url = URL("https://www.google.com")
                val connection = url.openConnection() as HttpURLConnection
                connection.requestMethod = "HEAD"
                connection.connectTimeout = 2000 // 2 seconds - fast check
                connection.readTimeout = 2000
                connection.connect()
                connection.disconnect()
                true
            } catch (e: Exception) {
                Log.d(TAG, "🌐 Network connectivity check failed: ${e.message}")
                false
            }
        }
    }
    
    /**
     * Check server health via HTTP (fallback when WebSocket fails)
     */
    private suspend fun checkServerHealth(): Boolean {
        // First check if we have network connectivity
        if (!checkNetworkConnectivity()) {
            Log.d(TAG, "🌐 No network connectivity - server unreachable")
            return false
        }
        
        return withContext(Dispatchers.IO) {
            try {
                // Convert WebSocket URL to HTTP health endpoint
                val healthUrl = (cloudConfig.url ?: throw IllegalStateException("Cloud config URL cannot be null"))
                    .replaceFirst("wss://", "https://")
                    .replaceFirst("ws://", "http://")
                    .removeSuffix("/ws")
                    .let { url -> if (url.endsWith("/")) url else "$url/" }
                    .plus("health")
                val url = URL(healthUrl)
                val connection = url.openConnection() as HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 3000 // 3 seconds - faster check
                connection.readTimeout = 3000
                connection.connect()
                
                val responseCode = connection.responseCode
                connection.disconnect()
                
                responseCode == 200
            } catch (e: Exception) {
                Log.w(TAG, "🏥 Server health check failed: ${e.message}")
                false
            }
        }
    }
    
    /**
     * Probe connection status for all paired devices.
     * Checks both LAN (via discovery + active WebSocket connections) and Cloud (via backend query).
     */
    private suspend fun probeConnections() {
        if (isProbing) {
            return
        }
        
        isProbing = true
        try {
            // Check network connectivity for device status updates
            val hasNetwork = checkNetworkConnectivity()
            if (!hasNetwork) {
                // Network is offline - mark all devices as offline
                val pairedDeviceIds = runCatching {
                    deviceKeyStore.getAllDeviceIds().toSet()
                }.getOrElse { emptySet() }
                val offlineStatuses = pairedDeviceIds.associateWith {
                    com.hypo.clipboard.ui.components.DeviceDualStatus(
                        isConnectedViaLan = false,
                        isConnectedViaCloud = false
                    )
                }
                _deviceDualStatus.value = offlineStatuses
                return
            }
            
            // Get paired device IDs from DeviceKeyStore (devices with encryption keys)
            val pairedDeviceIds = runCatching {
                deviceKeyStore.getAllDeviceIds().toList()
            }.getOrElse { emptyList() }
            
            // Query cloud for connected peers (if cloud is connected)
            // Privacy-preserving: only query status for devices we already know about
            val cloudConnectedDevices = if (cloudWebSocketClient.isConnected()) {
                try {
                    val connectedPeers = cloudWebSocketClient.queryConnectedPeers(peerIds = pairedDeviceIds)
                    val devicesWithNames = connectedPeers.map { peer ->
                        if (peer.name != null) "${peer.deviceId} (${peer.name})" else peer.deviceId
                    }
                    Log.d(TAG, "☁️ Cloud query returned ${connectedPeers.size} connected devices: $devicesWithNames")
                    connectedPeers.map { it.deviceId }.toSet()
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Failed to query cloud for connected peers: ${e.message}", e)
                    emptySet()
                }
            } else {
                emptySet()
            }
            
            // Get active LAN connections (devices with active WebSocket connections)
            val activeLanConnections = transportManager.getActiveLanConnections()
            

            
            // Build dual status map for each paired device
            val dualStatuses = mutableMapOf<String, com.hypo.clipboard.ui.components.DeviceDualStatus>()
            
            for (deviceId in pairedDeviceIds) {
                // Check if device has a name - if not, it's an orphaned key from migration
                val deviceName = transportManager.getDeviceName(deviceId)
                if (deviceName == null) {
                    // Found an orphaned key (valid key in keystore, but no name in prefs)
                    // This happens if pairing was interrupted or during migration
                    // Heal the state by deleting the orphaned key
                    Log.w(TAG, "⚠️ Found orphaned key for device $deviceId (no name found). Deleting key to clean up state.")
                    runCatching {
                        deviceKeyStore.deleteKey(deviceId)
                        transportManager.forgetPairedDevice(deviceId)
                    }.onFailure { e ->
                        Log.e(TAG, "❌ Failed to delete orphaned key for $deviceId", e)
                    }
                    continue // Skip this device for status checks
                }
                
                val hasActiveLanConnection = activeLanConnections.contains(deviceId)
                val isConnectedViaLan = hasActiveLanConnection
                
                // Check Cloud status: device is in cloud-connected devices list
                val isConnectedViaCloud = cloudConnectedDevices.any { 
                    it.equals(deviceId, ignoreCase = true) || 
                    it == deviceId
                }
                
                dualStatuses[deviceId] = com.hypo.clipboard.ui.components.DeviceDualStatus(
                    isConnectedViaLan = isConnectedViaLan,
                    isConnectedViaCloud = isConnectedViaCloud
                )
                
                val deviceLabel = "$deviceId ($deviceName)"
                Log.d(TAG, "📊 Device $deviceLabel: LAN=${isConnectedViaLan}, Cloud=${isConnectedViaCloud}")
            }
            
            _deviceDualStatus.value = dualStatuses
            
            // Update TransportManager global connection state (mirrors macOS behavior)
            // This ensures the global UI badge updates correctly when peers disconnect
            val isCloudConnected = cloudWebSocketClient.isConnected()
            if (isCloudConnected) {
                transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectedCloud)
            } else if (activeLanConnections.isNotEmpty()) {
                transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectedLan)
            } else {
                transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.Disconnected)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error probing connections: ${e.message}", e)
        } finally {
            isProbing = false
        }
    }
}
