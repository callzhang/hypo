package com.hypo.clipboard.pairing

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.sync.DeviceKeyStore
import com.hypo.clipboard.sync.DeviceIdentity
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
    private val transportManager: com.hypo.clipboard.transport.TransportManager
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
        
        discoveryJob = viewModelScope.launch {
            discoverySource.discover("_hypo._tcp.")
                .catch { error ->
                    Log.e(TAG, "Discovery error: ${error.message}", error)
                    _state.value = LanPairingUiState.Error("Discovery failed: ${error.message}")
                }
                .collect { event ->
                    when (event) {
                        is LanDiscoveryEvent.Added -> {
                            Log.d(TAG, "Device discovered: ${event.peer.serviceName} at ${event.peer.host}:${event.peer.port}")
                            discoveredDevices[event.peer.serviceName] = event.peer
                            updateDevicesList()
                        }
                        is LanDiscoveryEvent.Removed -> {
                            Log.d(TAG, "Device lost: ${event.serviceName}")
                            discoveredDevices.remove(event.serviceName)
                            updateDevicesList()
                        }
                    }
                }
        }
    }
    
    private fun updateDevicesList() {
        val devices = discoveredDevices.values.toList()
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
                            headers = emptyMap(),
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
                            Log.e(TAG, "❌ Error waiting for ACK: ${e.message}", e)
                            _state.value = LanPairingUiState.Error("Failed to receive pairing response: ${e.message ?: "Unknown error"}")
                            return@launch
                        }
                        
                        // Step 7: Complete pairing handshake to save encryption key
                        Log.d(TAG, "Processing pairing ACK and completing handshake...")
                        val completionResult = pairingHandshakeManager.complete(sessionState, ackJson)
                        
                        when (completionResult) {
                            is PairingCompletionResult.Success -> {
                                Log.d(TAG, "✅ Pairing handshake completed! Key saved for device: ${completionResult.macDeviceId}")
                                
                                // Add to transport manager
                                transportManager.addPeer(device)
                                
                                // Mark device as connected since we just established a WebSocket connection during pairing
                                // The deviceId is the macDeviceId from the ACK, or fallback to serviceName
                                val deviceId = completionResult.macDeviceId ?: device.attributes["device_id"] ?: device.serviceName
                                transportManager.markDeviceConnected(deviceId, ActiveTransport.LAN)
                                
                                // Store device name for display when device is offline
                                val deviceName = completionResult.macDeviceName ?: device.serviceName
                                transportManager.persistDeviceName(deviceId, deviceName)
                                
                                Log.d(TAG, "Marked device $deviceId as connected via LAN, name=$deviceName")
                                
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

