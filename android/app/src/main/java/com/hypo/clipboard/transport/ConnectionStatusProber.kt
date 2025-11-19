package com.hypo.clipboard.transport

import android.util.Log
import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.sync.DeviceKeyStore
import com.hypo.clipboard.transport.ws.LanWebSocketClient
import com.hypo.clipboard.transport.ws.RelayWebSocketClient
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import java.net.HttpURLConnection
import java.net.URL
import java.time.Duration
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Periodically probes connection status to paired devices and updates their online status.
 * Checks on app launch, when app comes to foreground, and every 10 minutes.
 */
@Singleton
class ConnectionStatusProber @Inject constructor(
    private val transportManager: TransportManager,
    private val settingsRepository: SettingsRepository,
    private val deviceKeyStore: DeviceKeyStore,
    private val lanWebSocketClient: LanWebSocketClient,
    private val cloudWebSocketClient: RelayWebSocketClient
) {
    private val scope = CoroutineScope(SupervisorJob())
    private var periodicJob: Job? = null
    private var isProbing = false
    
    companion object {
        private const val TAG = "ConnectionStatusProber"
        private val PROBE_INTERVAL_MS = Duration.ofMinutes(10).toMillis() // 10 minutes
    }
    
    /**
     * Start periodic connection status probing
     */
    fun start() {
        stop() // Stop any existing job
        
        // Initial probe on launch
        scope.launch {
            probeConnections()
        }
        
        // Periodic probe every 10 minutes
        periodicJob = scope.launch {
            while (isActive) {
                delay(PROBE_INTERVAL_MS)
                if (isActive) {
                    probeConnections()
                }
            }
        }
        
        Log.i(TAG, "Connection status prober started - will probe every 10 minutes")
    }
    
    /**
     * Stop periodic probing
     */
    fun stop() {
        periodicJob?.cancel()
        periodicJob = null
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
     * Check server health via HTTP (fallback when WebSocket fails)
     */
    private suspend fun checkServerHealth(): Boolean {
        return withContext(Dispatchers.IO) {
            try {
                val url = URL("https://hypo.fly.dev/health")
                val connection = url.openConnection() as HttpURLConnection
                connection.requestMethod = "GET"
                connection.connectTimeout = 5000 // 5 seconds
                connection.readTimeout = 5000
                connection.connect()
                
                val responseCode = connection.responseCode
                connection.disconnect()
                
                val isHealthy = responseCode == 200
                if (isHealthy) {
                    Log.d(TAG, "🏥 Server health check passed (HTTP $responseCode)")
                } else {
                    Log.w(TAG, "🏥 Server health check failed (HTTP $responseCode)")
                }
                isHealthy
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
            Log.d(TAG, "Probe already in progress, skipping")
            return
        }
        
        isProbing = true
        try {
            Log.d(TAG, "Probing connection status for paired devices...")
            
            // Check cloud server availability via HTTP health check
            // This provides a fallback when WebSocket connection fails
            val serverReachable = checkServerHealth()
            if (serverReachable) {
                Log.d(TAG, "✅ Server is reachable via HTTP")
                transportManager.updateConnectionState(ConnectionState.ConnectedCloud)
            } else {
                Log.d(TAG, "❌ Server health check failed")
                // Don't update to Error immediately - might be temporary network issue
                // Only update if we have no other connections
            }
            
            // Get current peers (discovered devices)
            val peers = transportManager.currentPeers()
            Log.d(TAG, "Found ${peers.size} discovered peers")
            
            // Get last successful transport status from StateFlow
            val lastTransport = transportManager.lastSuccessfulTransport.value
            Log.d(TAG, "Found ${lastTransport.size} devices with transport status")
            
            // Get paired device IDs from DeviceKeyStore (devices with encryption keys)
            val pairedDeviceIds = runCatching {
                deviceKeyStore.getAllDeviceIds().toSet()
            }.getOrElse { emptySet() }
            Log.d(TAG, "Found ${pairedDeviceIds.size} paired devices")
            
            // Check connection status for each paired device
            for (deviceId in pairedDeviceIds) {
                val isDiscovered = peers.any { 
                    val peerDeviceId = it.attributes["device_id"] ?: it.serviceName
                    peerDeviceId == deviceId || it.serviceName == deviceId
                }
                
                val transport = lastTransport[deviceId]
                    ?: lastTransport.entries.firstOrNull { 
                        it.key.equals(deviceId, ignoreCase = true) ||
                        it.key.replace("-", "").equals(deviceId.replace("-", ""), ignoreCase = true)
                    }?.value
                
                val isOnline = when {
                    // Device is discovered AND has LAN transport → online
                    // For LAN, we consider it online if discovered (WebSocket will be established on-demand during sync)
                    isDiscovered && transport == ActiveTransport.LAN -> {
                        true // Device is on LAN, connection will be established when needed
                    }
                    // Device has CLOUD transport → online
                    transport == ActiveTransport.CLOUD -> {
                        // Cloud transport is considered online if we have transport status
                        // (RelayWebSocketClient manages its own connection lifecycle)
                        true
                    }
                    // Device is discovered but no transport → might be connecting, but still consider online
                    // This handles the case where device was just paired and transport status hasn't been set yet
                    isDiscovered -> {
                        // If device is discovered, mark it as LAN-connected (it's on the same network)
                        transportManager.markDeviceConnected(deviceId, ActiveTransport.LAN)
                        true
                    }
                    // Device not discovered and no transport → offline
                    else -> false
                }
                
                // Update transport status if device is online
                if (isOnline) {
                    if (transport == null && isDiscovered) {
                        // Device is discovered but no transport status yet - mark as LAN
                        transportManager.markDeviceConnected(deviceId, ActiveTransport.LAN)
                        Log.d(TAG, "✅ Device $deviceId is online via LAN (discovered, transport status set)")
                    } else if (transport != null) {
                        transportManager.markDeviceConnected(deviceId, transport)
                        Log.d(TAG, "✅ Device $deviceId is online via $transport")
                    }
                } else {
                    Log.d(TAG, "❌ Device $deviceId is offline (discovered=$isDiscovered, transport=$transport)")
                }
            }
            
            Log.i(TAG, "Probe complete")
        } catch (e: Exception) {
            Log.e(TAG, "Error probing connections: ${e.message}", e)
        } finally {
            isProbing = false
        }
    }
}

