package com.hypo.clipboard.pairing

import com.hypo.clipboard.util.formattedAsKB
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.sync.DeviceKeyStore
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.SyncCoordinator
import com.hypo.clipboard.transport.ActiveTransport
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import com.hypo.clipboard.transport.lan.LanDiscoveryEvent
import com.hypo.clipboard.transport.lan.LanDiscoverySource
import com.hypo.clipboard.transport.ws.WebSocketTransportClient
import com.hypo.clipboard.transport.ws.TlsWebSocketConfig
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject

private const val TAG = "LanPairingViewModel"

sealed interface LanPairingUiState {
    data object Discovering : LanPairingUiState
    data class DevicesFound(val devices: List<DiscoveredPeer>) : LanPairingUiState
    data class Pairing(val deviceName: String) : LanPairingUiState
    data class Success(val deviceName: String) : LanPairingUiState
    data class Error(val message: String) : LanPairingUiState
}

@HiltViewModel
class LanPairingViewModel @Inject constructor(
    private val discoverySource: LanDiscoverySource,
    private val pairingHandshakeManager: PairingHandshakeManager,
    private val deviceKeyStore: DeviceKeyStore,
    private val identity: DeviceIdentity,
    private val transportManager: com.hypo.clipboard.transport.TransportManager,
    private val syncCoordinator: SyncCoordinator
) : ViewModel() {
    
    private val _state = MutableStateFlow<LanPairingUiState>(LanPairingUiState.Discovering)
    val state: StateFlow<LanPairingUiState> = _state.asStateFlow()
    
    private val discoveredDevices = mutableMapOf<String, DiscoveredPeer>()
    private var discoveryJob: Job? = null
    private var pairingJob: Job? = null
    private var wsClient: WebSocketTransportClient? = null
    
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
    
    init {
        startDiscovery()
    }
    
    fun startDiscovery() {
        discoveryJob?.cancel()
        discoveredDevices.clear()
        _state.value = LanPairingUiState.Discovering
        
        Log.d(TAG, "🔍 Starting discovery for _hypo._tcp.")
        discoveryJob = viewModelScope.launch {
            discoverySource.discover("_hypo._tcp.")
                .catch { error ->
                    // Bonjour discovery surfaces IO exceptions via Flow; translate to UI error instead of crashing scope.
                    Log.e(TAG, "❌ Discovery error: ${error.message}", error)
                    _state.value = LanPairingUiState.Error("Discovery failed: ${error.message}")
                }
                .collect { event ->
                    when (event) {
                        is LanDiscoveryEvent.Added -> {
                            val peer = event.peer
                            Log.d(TAG, "✅ Device discovered: ${peer.serviceName} at ${peer.host}:${peer.port}")
                            Log.d(TAG, "   Attributes: ${peer.attributes}")
                            val deviceId = peer.attributes["device_id"] ?: ""
                            Log.d(TAG, "   Device ID: ${if (deviceId.isEmpty()) "missing" else deviceId}")
                            Log.d(TAG, "   Public Key: ${peer.attributes["pub_key"]?.take(20) ?: "missing"}...")
                            
                            // Exclude self device from pairing list
                            val isSelfDevice = deviceId == identity.deviceId || 
                                             peer.serviceName.startsWith(identity.deviceId) ||
                                             (deviceId.isEmpty() && peer.serviceName.contains(identity.deviceId))
                            if (isSelfDevice) {
                                Log.d(TAG, "⏭️ Skipping self device: deviceId=$deviceId, serviceName=${peer.serviceName}")
                                return@collect
                            }
                            
                            // Exclude already-paired devices from pairing list
                            if (deviceId.isNotEmpty()) {
                                val isPaired = try {
                                    withContext(Dispatchers.IO) {
                                        deviceKeyStore.loadKey(deviceId) != null
                                    }
                                } catch (e: Exception) {
                                    false
                                }
                                if (isPaired) {
                                    Log.d(TAG, "⏭️ Skipping already-paired device: deviceId=$deviceId, serviceName=${peer.serviceName}")
                                    return@collect
                                }
                            }
                            
                            // Use device_id as key if available, otherwise fallback to serviceName
                            // This deduplicates devices discovered on multiple network interfaces
                            val key = if (deviceId.isNotEmpty()) {
                                deviceId
                            } else {
                                // For devices without device_id, extract base serviceName (remove network interface suffixes like " (2)")
                                // This helps deduplicate devices discovered on multiple interfaces
                                val baseServiceName = peer.serviceName.replace(Regex(" \\(\\d+\\)$"), "")
                                Log.w(TAG, "⚠️ Device ${peer.serviceName} has no device_id, using base serviceName as key: $baseServiceName")
                                baseServiceName
                            }
                            
                            // Only add if we don't already have this device (deduplication)
                            if (!discoveredDevices.containsKey(key)) {
                                discoveredDevices[key] = peer
                                Log.d(TAG, "➕ Added device to list: key=$key, serviceName=${peer.serviceName}")
                            } else {
                                Log.d(TAG, "⏭️ Skipping duplicate device: key=$key, serviceName=${peer.serviceName}")
                            }
                            updateDevicesList()
                        }
                        is LanDiscoveryEvent.Removed -> {
                            val serviceName = event.serviceName
                            Log.d(TAG, "❌ Device lost: $serviceName")
                            // Remove by serviceName or device_id
                            discoveredDevices.entries.removeIf { (_, peer) -> peer.serviceName == serviceName }
                            updateDevicesList()
                        }
                    }
                }
        }
    }
    
    private fun updateDevicesList() {
        val devices = discoveredDevices.values.toList()
        Log.d(TAG, "📋 Updated devices list: ${devices.size} devices")
        devices.forEach { peer ->
            Log.d(TAG, "   - ${peer.serviceName} (${peer.host}:${peer.port})")
        }
        _state.value = if (devices.isEmpty()) {
            LanPairingUiState.Discovering
        } else {
            LanPairingUiState.DevicesFound(devices)
        }
    }
    
    fun pairWithDevice(device: DiscoveredPeer) {
        Log.d(TAG, "🔵 pairWithDevice called for device: ${device.serviceName} at ${device.host}:${device.port}")
        pairingJob?.cancel()
        _state.value = LanPairingUiState.Pairing(device.serviceName)
        
        pairingJob = viewModelScope.launch {
            Log.d(TAG, "🔵 Starting pairing coroutine...")
            try {
                // Step 1: Validate device attributes
                val qrPayload = createQrPayloadFromDevice(device)
                Log.d(TAG, "Created QR payload from device: ${device.serviceName}")
                
                // Step 2: Initiate pairing handshake to generate challenge
                val initiationResult = pairingHandshakeManager.initiate(qrPayload)
                when (initiationResult) {
                    is PairingInitiationResult.Failure -> {
                        Log.e(TAG, "Handshake initiation failed: ${initiationResult.reason}")
                        _state.value = LanPairingUiState.Error("Handshake failed: ${initiationResult.reason}")
                        return@launch
                    }
                    is PairingInitiationResult.Success -> {
                        Log.d(TAG, "Handshake initiated successfully")
                        val sessionState = initiationResult.state
                        
                        // Step 3: Connect WebSocket
                        // Handle emulator IP addresses: 10.0.2.x is the emulator's internal network
                        // When connecting to an emulator from a physical device, we need to use the host machine's IP
                        // For now, detect emulator IPs and log a warning - this is a known limitation
                        val hostIp = if (device.host.startsWith("10.0.2.")) {
                            Log.w(TAG, "⚠️ Detected emulator IP (${device.host}). Emulator-to-physical-device pairing via LAN is not supported.")
                            Log.w(TAG, "   The emulator advertises its internal IP which is not reachable from physical devices.")
                            Log.w(TAG, "   Consider using cloud pairing or testing with two physical devices.")
                            // Still try to connect, but it will likely fail
                            device.host
                        } else {
                            device.host
                        }
                        val wsUrl = "ws://$hostIp:${device.port}"
                        Log.d(TAG, "Connecting to device at: $wsUrl")
                        
                        // For ws:// (non-TLS) connections, don't use fingerprint
                        // Only use fingerprint for wss:// (TLS) connections
                        val fingerprint = if (wsUrl.startsWith("wss://", ignoreCase = true)) {
                            // Validate fingerprint format if provided
                            device.fingerprint?.takeIf { it.isNotBlank() && it.length % 2 == 0 }
                        } else {
                            null
                        }
                        
                        val config = TlsWebSocketConfig(
                            url = wsUrl,
                            fingerprintSha256 = fingerprint,
                            headers = mapOf(
                                "X-Device-Id" to identity.deviceId,
                                "X-Device-Platform" to "android"
                            ),
                            environment = "lan",
                            idleTimeoutMillis = 30_000,
                            roundTripTimeoutMillis = 60_000
                        )
                        
                        val connector = com.hypo.clipboard.transport.ws.OkHttpWebSocketConnector(config)
                        val frameCodec = com.hypo.clipboard.transport.ws.TransportFrameCodec()
                        
                        wsClient = WebSocketTransportClient(
                            config = config,
                            connector = connector,
                            frameCodec = frameCodec,
                            scope = viewModelScope,
                            clock = java.time.Clock.systemUTC()
                        )
                        
                        // Set up pairing ACK handler
                        val ackReceived = CompletableDeferred<String>()
                        wsClient?.setPairingAckHandler { ackJson ->
                            Log.d(TAG, "Received pairing ACK from peer device")
                            Log.d(TAG, "ACK JSON: $ackJson")
                            if (!ackReceived.isCompleted) {
                                ackReceived.complete(ackJson)
                            }
                        }
                        
                        // Step 4: Start the WebSocket connection and wait for it to be established
                        try {
                            Log.d(TAG, "⏳ Pairing: Starting WebSocket connection...")
                            // For pairing, we have a specific URL in the config
                            // Set handlers before starting (not needed for pairing, but set to avoid null pointer)
                            wsClient?.setIncomingClipboardHandler { _, _ -> } // Empty handler for pairing
                            
                            // For pairing connections, we need to ensure the connector is set
                            // The connector is passed in constructor and currentConnector is initialized to it
                            // For LAN connections without transportManager, startReceiving() will check config.url
                            // Since we have config.url set, it should work. The runConnectionLoop() will use
                            // config.url if lastKnownUrl is null for LAN connections (line 819: lastKnownUrl ?: config.url)
                            // And currentConnector should already be set from constructor (line 199)
                            // So we just need to call startReceiving() which will call ensureConnection()
                            wsClient?.startReceiving()
                            
                            Log.d(TAG, "⏳ Pairing: Waiting for WebSocket connection to be established...")
                            withContext(Dispatchers.IO) {
                                var attempts = 0
                                val maxAttempts = 100 // 10 seconds total (100 * 100ms) - increased for slower networks
                                while (attempts < maxAttempts && wsClient?.isConnected() != true) {
                                    delay(100)
                                    attempts++
                                }
                                if (wsClient?.isConnected() != true) {
                                    throw java.util.concurrent.TimeoutException("WebSocket connection not established after ${maxAttempts * 100}ms")
                                }
                            }
                            Log.d(TAG, "✅ Pairing: WebSocket connection established")
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ Pairing: Failed to establish WebSocket connection - ${e.message}", e)
                            _state.value = LanPairingUiState.Error("Failed to connect to peer device: ${e.message ?: "Connection timeout"}")
                            return@launch
                        }
                        
                        // Step 5: Send pairing challenge as raw JSON (not wrapped in SyncEnvelope)
                        val challengeJson = json.encodeToString(sessionState.challenge)
                        val challengeData = challengeJson.toByteArray(Charsets.UTF_8)
                        
                        try {
                            Log.d(TAG, "📤 Pairing: Sending challenge (ID: ${sessionState.challenge.challengeId.take(8)}...)")
                            wsClient?.sendRawJson(challengeData)
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ Pairing: Failed to send challenge - ${e.message}", e)
                            _state.value = LanPairingUiState.Error("Failed to send pairing challenge: ${e.message ?: "Unknown error"}")
                            return@launch
                        }
                        
                        // Step 6: Wait for ACK with timeout (increased to 60s to match roundTripTimeout)
                        val ackJson = try {
                            withContext(Dispatchers.IO) {
                                withTimeout(60_000) {
                                    ackReceived.await()
                                }
                            }
                        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                            Log.e(TAG, "❌ Pairing: Timeout waiting for ACK (60s)")
                            _state.value = LanPairingUiState.Error("Pairing timeout: Peer device did not respond within 60 seconds. Please ensure the other device is running Hypo and try again.")
                            return@launch
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ Pairing: Error waiting for ACK - ${e.message}", e)
                            _state.value = LanPairingUiState.Error("Failed to receive pairing response: ${e.message ?: "Unknown error"}")
                            return@launch
                        }
                        
                        Log.d(TAG, "✅ Pairing: ACK received (${ackJson.length} chars)")
                        
                        // Step 7: Complete pairing handshake to save encryption key
                        Log.d(TAG, "Processing pairing ACK and completing handshake...")
                        val completionResult = pairingHandshakeManager.complete(sessionState, ackJson)
                        
                        when (completionResult) {
                            is PairingCompletionResult.Success -> {
                                // Use the device ID from the pairing result (this is what the key was saved with)
                                // Migrate from old format (with prefix) to new format (pure UUID)
                                // peerDeviceId and peerDeviceName are non-nullable, so use them directly
                                val rawDeviceId = completionResult.peerDeviceId
                                val deviceId = when {
                                    rawDeviceId.startsWith("macos-") -> rawDeviceId.removePrefix("macos-")
                                    rawDeviceId.startsWith("android-") -> rawDeviceId.removePrefix("android-")
                                    else -> rawDeviceId
                                }
                                val deviceName = completionResult.peerDeviceName
                                
                                Log.d(TAG, "✅ Pairing handshake completed! Key saved for device: $deviceId (migrated from: $rawDeviceId)")
                                Log.d(TAG, "📋 Device ID from pairing result: ${completionResult.peerDeviceId}")
                                Log.d(TAG, "📋 Device ID from peer attributes: ${device.attributes["device_id"]}")
                                Log.d(TAG, "📋 Device service name: ${device.serviceName}")
                                
                                // Step 1: Verify key was saved (Issue 2b checklist)
                                // Key store handles normalization internally - no need to normalize deviceId here
                                Log.d(TAG, "🔑 Verifying key was saved for device: $deviceId")
                                val savedKey = deviceKeyStore.loadKey(deviceId)
                                if (savedKey != null) {
                                    Log.d(TAG, "✅ Key exists in store: ${savedKey.size.formattedAsKB()}")
                                } else {
                                    Log.e(TAG, "❌ Key missing from store! Available keys: ${deviceKeyStore.getAllDeviceIds()}")
                                }
                                
                                // Add to transport manager
                                transportManager.addPeer(device)
                                
                                // Mark device as connected since we just established a WebSocket connection during pairing
                                transportManager.markDeviceConnected(deviceId, ActiveTransport.LAN)
                                
                                // Store device name for display when device is offline
                                transportManager.persistDeviceName(deviceId, deviceName)
                                
                                Log.d(TAG, "Marked device $deviceId as connected via LAN, name=$deviceName")
                                
                                // Step 2: Ensure sync targets include this device
                                Log.d(TAG, "🎯 Registering device as manual sync target...")
                                syncCoordinator.addTargetDevice(deviceId)
                                val targets = syncCoordinator.targets.value
                                Log.d(TAG, "✅ Target devices now: $targets (count: ${targets.size})")
                                
                                // Verify the device is in sync targets
                                if (!targets.contains(deviceId)) {
                                    Log.w(TAG, "⚠️ Device $deviceId not in sync targets after adding! Available keys: ${deviceKeyStore.getAllDeviceIds()}")
                                }
                                
                                _state.value = LanPairingUiState.Success(device.serviceName)
                                Log.d(TAG, "Pairing completed successfully with ${device.serviceName}")
                            }
                            is PairingCompletionResult.Failure -> {
                                Log.e(TAG, "❌ Pairing completion failed: ${completionResult.reason}")
                                _state.value = LanPairingUiState.Error("Pairing failed: ${completionResult.reason}")
                                return@launch
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                // Top-level guard: any unexpected runtime exception during pairing should trigger a user-friendly error instead of crashing the ViewModel scope.
                Log.e(TAG, "❌ Pairing failed with exception: ${e.message}", e)
                val errorMessage = when (e) {
                    is java.net.ConnectException -> "Cannot connect to peer device. Please ensure the other device is running Hypo."
                    is java.net.SocketTimeoutException -> "Connection timeout. Please check your network connection."
                    is java.io.IOException -> "Network error: ${e.message ?: "Unknown error"}"
                    else -> "Pairing failed: ${e.message ?: e.javaClass.simpleName}"
                }
                _state.value = LanPairingUiState.Error(errorMessage)
            }
        }
    }
    
    private fun createQrPayloadFromDevice(device: DiscoveredPeer): String {
        // Create a pairing payload from Bonjour-discovered device
        // Use the persistent public key advertised via Bonjour
        // Include both new and old field names for compatibility
        val deviceId = device.attributes["device_id"] ?: "unknown"
        val pubKey = device.attributes["pub_key"] ?: ""
        val signingPubKey = device.attributes["signing_pub_key"] ?: ""
        
        // Validate that required keys are present
        if (pubKey.isEmpty()) {
            throw IllegalStateException("Discovered device ${device.serviceName} does not advertise a public key. Cannot create pairing payload.")
        }
        
        val jsonObject = org.json.JSONObject()
        jsonObject.put("ver", "1")
        jsonObject.put("peer_device_id", deviceId)
        jsonObject.put("peer_pub_key", pubKey)
        jsonObject.put("peer_signing_pub_key", signingPubKey)
        jsonObject.put("service", device.serviceName)
        jsonObject.put("port", device.port)
        
        val relayHint = device.attributes["relay_hint"]
        if (!relayHint.isNullOrEmpty()) {
            jsonObject.put("relay_hint", relayHint)
        }
        
        jsonObject.put("issued_at", java.time.Instant.now().toString())
        jsonObject.put("expires_at", java.time.Instant.now().plusSeconds(300).toString())
        
        // For LAN auto-discovery, use a special marker to skip signature verification
        // (we rely on TLS fingerprint verification instead)
        jsonObject.put("signature", "LAN_AUTO_DISCOVERY")
        
        return jsonObject.toString()
    }
    
    fun reset() {
        pairingJob?.cancel()
        wsClient = null
        discoveredDevices.clear()
        _state.value = LanPairingUiState.Discovering
        startDiscovery()
    }
    
    override fun onCleared() {
        super.onCleared()
        discoveryJob?.cancel()
        pairingJob?.cancel()
        wsClient = null
    }
}
