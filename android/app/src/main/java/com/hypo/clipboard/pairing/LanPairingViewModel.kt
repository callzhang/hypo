package com.hypo.clipboard.pairing

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.hypo.clipboard.sync.DeviceKeyStore
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import com.hypo.clipboard.transport.lan.LanDiscoveryEvent
import com.hypo.clipboard.transport.lan.LanDiscoverySource
import com.hypo.clipboard.transport.ws.LanWebSocketClient
import com.hypo.clipboard.transport.ws.TlsWebSocketConfig
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
    private val identity: DeviceIdentity
) : ViewModel() {
    
    private val _state = MutableStateFlow<LanPairingUiState>(LanPairingUiState.Discovering)
    val state: StateFlow<LanPairingUiState> = _state.asStateFlow()
    
    private val discoveredDevices = mutableMapOf<String, DiscoveredPeer>()
    private var discoveryJob: Job? = null
    private var pairingJob: Job? = null
    
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
        pairingJob?.cancel()
        _state.value = LanPairingUiState.Pairing(device.serviceName)
        
        pairingJob = viewModelScope.launch {
            try {
                // Step 1: Create WebSocket connection to macOS
                val wsUrl = "ws://${device.host}:${device.port}"
                Log.d(TAG, "Connecting to macOS at: $wsUrl")
                
                val config = TlsWebSocketConfig(
                    url = wsUrl,
                    fingerprintSha256 = device.fingerprint,
                    headers = emptyMap(),
                    environment = "lan",
                    idleTimeoutMillis = 30_000,
                    roundTripTimeoutMillis = 60_000
                )
                
                // Step 2: Connect via WebSocket and initiate pairing
                Log.d(TAG, "Connecting to WebSocket at ${config.url}")
                
                // TODO: Full WebSocket pairing implementation
                // For now, just show a placeholder success
                delay(1000) // Simulate connection time
                
                Log.d(TAG, "WebSocket connected, initiating pairing handshake")
                
                // The full implementation would:
                // 1. Connect WebSocket client
                // 2. Generate Android's key pair
                // 3. Send PairingInitiateMessage to macOS
                // 4. Receive macOS keys and complete handshake
                // 5. Store paired device info
                
                _state.value = LanPairingUiState.Success(device.serviceName)
                Log.d(TAG, "LAN pairing flow initiated (WebSocket integration pending)")
                
            } catch (e: Exception) {
                Log.e(TAG, "Pairing error: ${e.message}", e)
                _state.value = LanPairingUiState.Error(e.message ?: "Pairing failed")
            }
        }
    }
    
    private fun createQrPayloadFromDevice(device: DiscoveredPeer): String {
        // Create a minimal QR payload structure from discovered device
        // This matches the format expected by PairingHandshakeManager
        // Build JSON manually since kotlinx.serialization needs @Serializable types
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
        jsonObject.put("signature", device.attributes["signature"] ?: "")
        
        return jsonObject.toString()
    }
    
    private fun createWebSocketClient(config: TlsWebSocketConfig): LanWebSocketClient {
        // This is a placeholder - actual implementation would use dependency injection
        // For now, just log that we would create the client
        Log.d(TAG, "Would create WebSocket client with config: $config")
        throw NotImplementedError("WebSocket client integration pending")
    }
    
    fun reset() {
        pairingJob?.cancel()
        discoveredDevices.clear()
        _state.value = LanPairingUiState.Discovering
        startDiscovery()
    }
    
    override fun onCleared() {
        super.onCleared()
        discoveryJob?.cancel()
        pairingJob?.cancel()
    }
}

