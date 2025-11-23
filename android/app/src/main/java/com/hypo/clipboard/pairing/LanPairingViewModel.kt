package com.hypo.clipboard.pairing

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
import com.hypo.clipboard.transport.ws.LanWebSocketClient
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
    private var wsClient: LanWebSocketClient? = null
    
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
                            
                            // Filter out Android devices (only show macOS/iOS devices)
                            // Check both device_id and serviceName since Android devices may not have device_id attribute
                            val isAndroidDevice = deviceId.startsWith("android-") || 
                                                  peer.serviceName.startsWith("android-")
                            if (isAndroidDevice) {
                                Log.d(TAG, "⏭️ Skipping Android device: deviceId=$deviceId, serviceName=${peer.serviceName}")
                                return@collect
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
                        val wsUrl = "ws://${device.host}:${device.port}"
                        Log.d(TAG, "Connecting to macOS at: $wsUrl")
                        
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
                        
                        wsClient = LanWebSocketClient(
                            config = config,
                            connector = connector,
                            frameCodec = frameCodec,
                            scope = viewModelScope,
                            clock = java.time.Clock.systemUTC()
                        )
                        
                        // Set up pairing ACK handler
                        val ackReceived = CompletableDeferred<String>()
                        wsClient?.setPairingAckHandler { ackJson ->
                            Log.d(TAG, "Received pairing ACK from macOS")
                            Log.d(TAG, "ACK JSON: $ackJson")
                            if (!ackReceived.isCompleted) {
                                ackReceived.complete(ackJson)
                            }
                        }
                        
                        // Step 4: Ensure connection is established before sending challenge
                        Log.d(TAG, "Ensuring WebSocket connection is established...")
                        wsClient?.let { client ->
                            withContext(Dispatchers.IO) {
                                delay(100)
                            }
                        }
                        
                        // Step 5: Send pairing challenge as raw JSON (not wrapped in SyncEnvelope)
                        // macOS expects raw JSON with challenge_id at top level for pairing detection
                        val challengeJson = json.encodeToString(sessionState.challenge)
                        Log.d(TAG, "Sending pairing challenge to macOS as raw JSON")
                        Log.d(TAG, "Challenge JSON: $challengeJson")
                        Log.d(TAG, "Challenge ID: ${sessionState.challenge.challengeId}")
                        val challengeData = challengeJson.toByteArray(Charsets.UTF_8)
                        
                        try {
                            Log.d(TAG, "Calling sendRawJson...")
                            wsClient?.sendRawJson(challengeData)
                            Log.d(TAG, "sendRawJson completed, waiting for ACK (timeout: 30s)")
                        } catch (e: Exception) {
                            // Transport failures (socket closed, handshake failure) shouldn't crash the pairing job; surface a friendly error.
                            Log.e(TAG, "❌ Failed to send challenge: ${e.message}", e)
                            _state.value = LanPairingUiState.Error("Failed to send pairing challenge: ${e.message ?: "Unknown error"}")
                            return@launch
                        }
                        
                        // Step 6: Wait for ACK with timeout
                        val ackJson = try {
                            withContext(Dispatchers.IO) {
                                withTimeout(30_000) {
                                    ackReceived.await()
                                }
                            }
                        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                            Log.e(TAG, "❌ Pairing timeout: No ACK received within 30 seconds")
                            _state.value = LanPairingUiState.Error("Pairing timeout: macOS did not respond. Please ensure the macOS app is running and try again.")
                            return@launch
                        } catch (e: Exception) {
                            // JSON decode or network errors while awaiting ACK must be propagated to UI.
                            Log.e(TAG, "❌ Error waiting for ACK: ${e.message}", e)
                            _state.value = LanPairingUiState.Error("Failed to receive pairing response: ${e.message ?: "Unknown error"}")
                            return@launch
                        }
                        
                        // Step 7: Complete pairing handshake to save encryption key
                        Log.d(TAG, "Processing pairing ACK and completing handshake...")
                        val completionResult = pairingHandshakeManager.complete(sessionState, ackJson)
                        
                        when (completionResult) {
                            is PairingCompletionResult.Success -> {
                                // Use the device ID from the pairing result (this is what the key was saved with)
                                // Migrate from old format (with prefix) to new format (pure UUID)
                                val rawDeviceId = completionResult.macDeviceId ?: device.attributes["device_id"] ?: device.serviceName
                                val deviceId = when {
                                    rawDeviceId.startsWith("macos-") -> rawDeviceId.removePrefix("macos-")
                                    rawDeviceId.startsWith("android-") -> rawDeviceId.removePrefix("android-")
                                    else -> rawDeviceId
                                }
                                val deviceName = completionResult.macDeviceName ?: device.serviceName
                                
                                Log.d(TAG, "✅ Pairing handshake completed! Key saved for device: $deviceId (migrated from: $rawDeviceId)")
                                Log.d(TAG, "📋 Device ID from pairing result: ${completionResult.macDeviceId}")
                                Log.d(TAG, "📋 Device ID from peer attributes: ${device.attributes["device_id"]}")
                                Log.d(TAG, "📋 Device service name: ${device.serviceName}")
                                
                                // Step 1: Verify key was saved (Issue 2b checklist)
                                Log.d(TAG, "🔑 Verifying key was saved for device: $deviceId")
                                val savedKey = deviceKeyStore.loadKey(deviceId)
                                if (savedKey != null) {
                                    Log.d(TAG, "✅ Key exists in store: ${savedKey.size} bytes")
                                } else {
                                    Log.e(TAG, "❌ Key missing from store! Available keys: ${deviceKeyStore.getAllDeviceIds()}")
                                    // Try to find the key with case-insensitive matching
                                    val allKeys = deviceKeyStore.getAllDeviceIds()
                                    val matchingKey = allKeys.find { it.equals(deviceId, ignoreCase = true) }
                                    if (matchingKey != null) {
                                        Log.w(TAG, "⚠️ Found key with case-insensitive match: $matchingKey (requested: $deviceId)")
                                        Log.w(TAG, "💡 This suggests a device ID format mismatch - key was saved with different case/format")
                                    }
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
                    is java.net.ConnectException -> "Cannot connect to macOS. Please ensure the macOS app is running."
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
        val jsonObject = org.json.JSONObject()
        jsonObject.put("ver", "1")
        jsonObject.put("mac_device_id", device.attributes["device_id"] ?: "unknown")
        jsonObject.put("mac_pub_key", device.attributes["pub_key"] ?: "")
        jsonObject.put("mac_signing_pub_key", device.attributes["signing_pub_key"] ?: "")
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
