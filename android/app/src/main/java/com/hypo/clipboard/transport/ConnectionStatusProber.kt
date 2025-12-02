package com.hypo.clipboard.transport

import android.util.Log
import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.sync.DeviceKeyStore
import com.hypo.clipboard.transport.ws.WebSocketTransportClient
import com.hypo.clipboard.transport.ws.RelayWebSocketClient
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.collect
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
    private var isProbing = false
    
    companion object {
        private const val TAG = "ConnectionStatusProber"
        // Safety timer interval for belt-and-suspenders (debugging builds) or as fallback
        // Only used if event-driven observation fails
        private val SAFETY_TIMER_INTERVAL_MS = Duration.ofMinutes(5).toMillis() // 5 minutes - safety net
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
        
        // Event-driven: observe peers changes
        // StateFlow already deduplicates, so we only need debounce to avoid rapid-fire probes
        peersObserverJob = scope.launch {
            transportManager.peers
                .debounce(DEBOUNCE_DELAY_MS)
                .collect {
                    Log.d(TAG, "📡 Peers changed (${it.size} peers), triggering probe")
                    probeConnections()
                }
        }
        
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
     * Probe connection status for all paired devices
     */
    private suspend fun probeConnections() {
        if (isProbing) {
            return
        }
        
        isProbing = true
        try {
            // Connection state is now updated event-driven from WebSocket callbacks (onOpen/onClosed/onFailure)
            // This probe only updates device online status based on discovery and transport info
            // No need to check connection state here - it's already updated by WebSocket clients
            
            // Check network connectivity for device status updates
            val hasNetwork = checkNetworkConnectivity()
            if (!hasNetwork) {
                // Network is offline - connection state will be updated by network change callbacks
                // Just continue to update device status
            }
            
            // Compute cloud reachability once per probe (reuse in device loop)
            // Use checkServerHealth() when WebSocket is disconnected but network is available
            val cloudConnected = cloudWebSocketClient.isConnected()
            val cloudReachable = cloudConnected || (hasNetwork && checkServerHealth())
            
            // Get current peers (discovered devices)
            val peers = transportManager.currentPeers()
            
            // Get last successful transport status from StateFlow
            val lastTransport = transportManager.lastSuccessfulTransport.value
            
            // Get paired device IDs from DeviceKeyStore (devices with encryption keys)
            val pairedDeviceIds = runCatching {
                deviceKeyStore.getAllDeviceIds().toSet()
            }.getOrElse { emptySet() }
            
            // Check connection status for each paired device
            // Note: If network is offline (hasNetwork = false), all peers are offline
            // SettingsViewModel will mark them as Disconnected based on connectionState being Disconnected
            for (deviceId in pairedDeviceIds) {
                // If no network, skip peer status updates (SettingsViewModel handles it via connectionState)
                if (!hasNetwork) {
                    continue
                }
                
                val isDiscovered = peers.any { 
                    val peerDeviceId = it.attributes["device_id"] ?: it.serviceName
                    // Case-insensitive matching for device IDs
                    peerDeviceId.equals(deviceId, ignoreCase = true) || 
                    it.serviceName.equals(deviceId, ignoreCase = true) ||
                    peerDeviceId == deviceId || 
                    it.serviceName == deviceId
                }
                
                val transport = lastTransport[deviceId]
                    ?: lastTransport.entries.firstOrNull { 
                        it.key.equals(deviceId, ignoreCase = true) ||
                        it.key.replace("-", "").equals(deviceId.replace("-", ""), ignoreCase = true)
                    }?.value
                
                // Use cloudReachable (computed once above) instead of just cloudConnected
                
                val isOnline = when {
                    // Device is discovered on LAN → online (LAN connection will be established on-demand during sync)
                    isDiscovered -> true
                    // Device has CLOUD transport AND cloud server is reachable → online via cloud
                    transport == ActiveTransport.CLOUD && cloudReachable -> true
                    // Device has CLOUD transport but cloud server not reachable → offline
                    transport == ActiveTransport.CLOUD -> false
                    // Device not discovered and no transport → offline
                    else -> false
                }
                
                // Update transport status if device is online
                if (isOnline) {
                    if (transport == null && isDiscovered) {
                        // Device is discovered but no transport status yet - mark as LAN
                        transportManager.markDeviceConnected(deviceId, ActiveTransport.LAN)
                    } else if (transport != null) {
                        transportManager.markDeviceConnected(deviceId, transport)
                    }
                } else if (!isDiscovered && transport == null && cloudReachable) {
                    // Device is not discovered on LAN, has no transport, but cloud is reachable
                    // Mark it with CLOUD transport so it shows as online via cloud
                    transportManager.markDeviceConnected(deviceId, ActiveTransport.CLOUD)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error probing connections: ${e.message}", e)
        } finally {
            isProbing = false
        }
    }
}
