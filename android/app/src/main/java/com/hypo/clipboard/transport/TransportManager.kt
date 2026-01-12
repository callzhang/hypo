package com.hypo.clipboard.transport

import com.hypo.clipboard.util.formattedAsKB
import android.content.Context
import android.content.SharedPreferences
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import com.hypo.clipboard.transport.lan.LanDiscoveryEvent
import com.hypo.clipboard.transport.lan.LanDiscoverySource
import com.hypo.clipboard.transport.lan.LanRegistrationConfig
import com.hypo.clipboard.transport.lan.LanRegistrationController
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.withContext
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.min
import kotlin.random.Random
import kotlin.collections.buildMap

class TransportManager(
    private val discoverySource: LanDiscoverySource,
    private val registrationController: LanRegistrationController,
    private val context: Context? = null,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val clock: Clock = Clock.systemUTC(),
    private val pruneInterval: Duration = Duration.ofMinutes(1),
    private val staleThreshold: Duration = Duration.ofMinutes(5),
    private val analytics: TransportAnalytics = NoopTransportAnalytics
) {
    private var webSocketServer: com.hypo.clipboard.transport.ws.LanWebSocketServer? = null
    private val stateLock = Any()
    private val peersByService = mutableMapOf<String, DiscoveredPeer>()
    private val lastSeenByService = mutableMapOf<String, Instant>()
    // Track cloud and LAN connection states separately to prevent one from overwriting the other
    private val _cloudConnectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    private val _lanConnectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    // Keep track of pending removals for cancellation (but we don't actually remove peers anymore)
    private val pendingPeerRemovalJobs = mutableMapOf<String, Job>()

    private val _peers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    private val _lastSeen = MutableStateFlow<Map<String, Instant>>(emptyMap())
    private val _isAdvertising = MutableStateFlow(false)
    private val _connectionState = MutableStateFlow(ConnectionState.Disconnected)
    private val prefs: SharedPreferences? = context?.getSharedPreferences("transport_status", Context.MODE_PRIVATE)
    private val _lastSuccessfulTransport = MutableStateFlow<Map<String, ActiveTransport>>(loadPersistedTransportStatus())
    
    private fun loadPersistedTransportStatus(): Map<String, ActiveTransport> {
        if (prefs == null) {
            android.util.Log.w("TransportManager", "⚠️ No SharedPreferences available, cannot load persisted transport status")
            return emptyMap()
        }
        val allEntries = prefs.all
        val result = mutableMapOf<String, ActiveTransport>()
        android.util.Log.d("TransportManager", "📦 Loading persisted transport status from SharedPreferences (${allEntries.size} entries)")
        for ((key, value) in allEntries) {
            if (key.startsWith("transport_")) {
                val deviceId = key.removePrefix("transport_")
                val transportName = value as? String ?: continue
                val transport = try {
                    ActiveTransport.valueOf(transportName)
                } catch (e: IllegalArgumentException) {
                    android.util.Log.w("TransportManager", "⚠️ Invalid transport name: $transportName for device: $deviceId")
                    continue
                }
                result[deviceId] = transport
                android.util.Log.d("TransportManager", "✅ Loaded persisted status: device=$deviceId, transport=$transport")
            }
        }
        android.util.Log.d("TransportManager", "📦 Loaded ${result.size} persisted transport status entries")
        return result
    }
    
    private fun persistTransportStatus(deviceId: String, transport: ActiveTransport) {
        if (prefs == null) {
            android.util.Log.w("TransportManager", "⚠️ No SharedPreferences available, cannot persist transport status for device: $deviceId")
            return
        }
        val key = "transport_$deviceId"
        try {
            val editor = prefs.edit()
            if (editor == null) {
                android.util.Log.e("TransportManager", "❌ Failed to get SharedPreferences editor")
                return
            }
            editor.putString(key, transport.name)
            val success = editor.commit()
            if (!success) {
                android.util.Log.e("TransportManager", "❌ commit() returned false for key=$key")
            }
        } catch (e: Exception) {
            android.util.Log.e("TransportManager", "❌ Exception persisting transport status: ${e.message}", e)
        }
    }
    
    fun persistDeviceName(deviceId: String, deviceName: String) {
        if (prefs == null) {
            android.util.Log.w("TransportManager", "⚠️ No SharedPreferences available, cannot persist device name for device: $deviceId")
            return
        }
        // Normalize device ID to lowercase for consistent storage
        val normalizedId = deviceId.lowercase().removePrefix("macos-").removePrefix("android-")
        val key = "device_name_$normalizedId"
        prefs.edit().putString(key, deviceName).commit()
        android.util.Log.d("TransportManager", "💾 Persisted device name: device=$deviceId (normalized: $normalizedId), name=$deviceName")
    }
    
    fun getDeviceName(deviceId: String): String? {
        if (prefs == null) return null
        
        // Normalize device ID to lowercase for consistent lookup
        val normalizedId = deviceId.lowercase()
        
        // Try with the normalized device ID first
        var key = "device_name_$normalizedId"
        var name = prefs.getString(key, null)
        if (name != null) {
            // Log at verbose level since this is called frequently during UI updates
            android.util.Log.v("TransportManager", "✅ Found device name for $deviceId (normalized: $normalizedId): $name")
            return name
        }
        
        // Try with original case (in case it was stored with original case)
        if (deviceId != normalizedId) {
            key = "device_name_$deviceId"
            name = prefs.getString(key, null)
            if (name != null) {
                android.util.Log.v("TransportManager", "✅ Found device name for $deviceId (original case): $name")
                return name
            }
        }
        
        // If not found, try with migrated format (remove prefixes)
        // This handles cases where persistDeviceName was called with prefixed ID
        // but getAllDeviceIds returns migrated (unprefixed) IDs
        val migratedId = normalizedId.removePrefix("macos-").removePrefix("android-")
        if (migratedId != normalizedId) {
            key = "device_name_$migratedId"
            name = prefs.getString(key, null)
            if (name != null) {
                android.util.Log.v("TransportManager", "✅ Found device name for $deviceId (migrated: $migratedId): $name")
                return name
            }
        }
        
        // Also try with prefixes added (in case getAllDeviceIds returned unprefixed but name was stored with prefix)
        for (prefix in listOf("macos-", "android-")) {
            key = "device_name_${prefix}$normalizedId"
            name = prefs.getString(key, null)
            if (name != null) {
                android.util.Log.v("TransportManager", "✅ Found device name for $deviceId (with prefix $prefix): $name")
                return name
            }
        }
        
        android.util.Log.w("TransportManager", "⚠️ No device name found for $deviceId (tried: $normalizedId, $deviceId, $migratedId, and with prefixes)")
        return null
    }
    
    private fun clearPersistedTransportStatus(deviceId: String) {
        prefs?.edit()?.remove("transport_$deviceId")?.apply()
    }

    private var discoveryJob: Job? = null
    private var pruneJob: Job? = null
    private var healthCheckJob: Job? = null
    private var connectionJob: Job? = null
    private var networkSignalJob: Job? = null
    private var currentConfig: LanRegistrationConfig? = null
    private val manualRetryRequested = AtomicBoolean(false)
    private val networkChangeDetected = AtomicBoolean(false)
    private var onPairingChallenge: (suspend (String) -> String?)? = null
    private var onIncomingClipboard: ((com.hypo.clipboard.sync.SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit)? = null
    private var lanPeerConnectionManager: com.hypo.clipboard.transport.ws.LanPeerConnectionManager? = null

    val peers: StateFlow<List<DiscoveredPeer>> = _peers.asStateFlow()
    val isAdvertising: StateFlow<Boolean> = _isAdvertising.asStateFlow()
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()
    // Cloud-only connection state for UI - tracks cloud state separately from LAN
    val cloudConnectionState: StateFlow<ConnectionState> = _cloudConnectionState.asStateFlow()
    val lastSuccessfulTransport: StateFlow<Map<String, ActiveTransport>> =
        _lastSuccessfulTransport.asStateFlow()
    
    /**
     * Update the connection state (used by ConnectionStatusProber)
     * Now tracks cloud and LAN states separately to prevent one from overwriting the other
     */
    fun updateConnectionState(newState: ConnectionState) {
        val oldState = _connectionState.value
        android.util.Log.d("TransportManager", "🔄 Updating connection state: $oldState -> $newState")
        
        // Update the appropriate state based on connection type
        when (newState) {
            ConnectionState.ConnectedCloud, ConnectionState.ConnectingCloud, ConnectionState.Disconnected -> {
                // Cloud connection state change - update cloud state
                val oldCloudState = _cloudConnectionState.value
                _cloudConnectionState.value = newState
                android.util.Log.d("TransportManager", "☁️ Cloud connection state: $oldCloudState -> $newState")
            }
            ConnectionState.ConnectedLan, ConnectionState.ConnectingLan -> {
                // LAN connection state change - update LAN state only, don't affect cloud
                val oldLanState = _lanConnectionState.value
                _lanConnectionState.value = newState
                android.util.Log.d("TransportManager", "📡 LAN connection state: $oldLanState -> $newState")
                // Don't update _connectionState for LAN - keep cloud state if cloud is connected
                if (_cloudConnectionState.value == ConnectionState.ConnectedCloud || 
                    _cloudConnectionState.value == ConnectionState.ConnectingCloud) {
                    android.util.Log.d("TransportManager", "   Cloud is connected, keeping cloud state as primary")
                    return // Don't overwrite cloud state
                }
            }
            else -> {
                // Other states (Error, etc.) - update both if needed
            }
        }
        
        // Update primary connection state (prioritize cloud over LAN)
        _connectionState.value = when {
            _cloudConnectionState.value == ConnectionState.ConnectedCloud -> ConnectionState.ConnectedCloud
            _cloudConnectionState.value == ConnectionState.ConnectingCloud -> ConnectionState.ConnectingCloud
            _lanConnectionState.value == ConnectionState.ConnectedLan -> ConnectionState.ConnectedLan
            _lanConnectionState.value == ConnectionState.ConnectingLan -> ConnectionState.ConnectingLan
            else -> newState
        }
        
        // Log the mapped cloudConnectionState for debugging
        val mapped = when (_connectionState.value) {
            ConnectionState.ConnectedCloud -> ConnectionState.ConnectedCloud
            ConnectionState.ConnectingCloud -> ConnectionState.ConnectingCloud
            ConnectionState.ConnectedLan, ConnectionState.ConnectingLan -> ConnectionState.Disconnected
            else -> _connectionState.value
        }
        android.util.Log.d("TransportManager", "🌐 cloudConnectionState will be: $mapped (from ${_connectionState.value})")
    }

    fun start(config: LanRegistrationConfig) {
        android.util.Log.d("TransportManager", "🚀 TransportManager.start() called: serviceName=${config.serviceName}, port=${config.port}, serviceType=${config.serviceType}")
        android.util.Log.d("TransportManager", "📝 Calling registrationController.start()...")
        currentConfig = config
        registrationController.start(config)
        android.util.Log.d("TransportManager", "✅ registrationController.start() called, isAdvertising=${_isAdvertising.value}")
        _isAdvertising.value = true
        
        // Start WebSocket server to accept incoming connections
        if (webSocketServer == null && config.port > 0) {
            android.util.Log.d("TransportManager", "🚀 Starting WebSocket server on port ${config.port}")
            webSocketServer = com.hypo.clipboard.transport.ws.LanWebSocketServer(config.port, scope)
            webSocketServer?.delegate = object : com.hypo.clipboard.transport.ws.LanWebSocketServerDelegate {
                override fun onPairingChallenge(server: com.hypo.clipboard.transport.ws.LanWebSocketServer, challenge: com.hypo.clipboard.pairing.PairingChallengeMessage, connectionId: String) {
                    android.util.Log.d("TransportManager", "📱 Received pairing challenge from $connectionId")
                    // Delegate to service-level handler (set via setPairingChallengeHandler)
                    scope.launch {
                        val challengeJson = com.hypo.clipboard.transport.ws.LanWebSocketServer.json.encodeToString(
                            com.hypo.clipboard.pairing.PairingChallengeMessage.serializer(),
                            challenge
                        )
                        val ackJson = onPairingChallenge?.invoke(challengeJson)
                        if (ackJson != null) {
                            android.util.Log.d("TransportManager", "📤 Sending pairing ACK to $connectionId")
                            server.sendPairingAck(ackJson, connectionId)
                        } else {
                            android.util.Log.w("TransportManager", "⚠️ Pairing challenge handler returned null ACK")
                        }
                    }
                }
                
                override fun onClipboardData(server: com.hypo.clipboard.transport.ws.LanWebSocketServer, data: ByteArray, connectionId: String) {
                    android.util.Log.d("TransportManager", "📋 Received clipboard data from connection $connectionId (${data.size.formattedAsKB()})")
                    
                    // Skip empty frames (could be ping/pong or malformed)
                    if (data.isEmpty()) {
                        android.util.Log.w("TransportManager", "⚠️ Received empty frame from connection $connectionId, skipping")
                        return
                    }
                    
                    // Skip frames that are too small to contain a valid frame header (4 bytes)
                    if (data.size < 4) {
                        android.util.Log.w("TransportManager", "⚠️ Received truncated frame from connection $connectionId (${data.size.formattedAsKB()} < 4), skipping")
                        return
                    }
                    
                    // Decode the binary frame and process clipboard data
                    scope.launch {
                        try {
                            // Decode the binary frame (4-byte length prefix + JSON payload)
                            val frameCodec = com.hypo.clipboard.transport.ws.TransportFrameCodec()
                            val envelope = frameCodec.decode(data)
                            android.util.Log.d("TransportManager", "✅ Decoded envelope: type=${envelope.type}, id=${envelope.id.take(8)}..., senderDeviceId=${envelope.payload.deviceId?.take(20)}...")
                            
                            // Check if this is from our own device ID (prevent echo loops)
                            // Note: We need access to DeviceIdentity to compare - this check will be done in IncomingClipboardHandler
                            // For now, we'll pass it through and let IncomingClipboardHandler filter it
                            
                            // No target filtering - process all messages and verify with UUID/key pairs only
                            // The message handler will verify decryption using the sender's device ID and stored keys
                            
                            // Pass to handler if set
                            if (envelope.type == com.hypo.clipboard.sync.MessageType.CLIPBOARD) {
                                if (onIncomingClipboard != null) {
                                    android.util.Log.d("TransportManager", "📤 Invoking incoming clipboard handler")
                                    onIncomingClipboard?.invoke(envelope, com.hypo.clipboard.domain.model.TransportOrigin.LAN)
                                } else {
                                    android.util.Log.w("TransportManager", "⚠️ No incoming clipboard handler set, message dropped")
                                }
                            } else {
                                android.util.Log.w("TransportManager", "⚠️ Received non-clipboard message type: ${envelope.type}")
                            }
                        } catch (e: Exception) {
                            android.util.Log.e("TransportManager", "❌ Failed to decode clipboard data: ${e.message}", e)
                        }
                    }
                }
                
                override fun onConnectionAccepted(server: com.hypo.clipboard.transport.ws.LanWebSocketServer, connectionId: String) {
                    android.util.Log.d("TransportManager", "✅ Connection accepted: $connectionId")
                }
                
                override fun onConnectionClosed(server: com.hypo.clipboard.transport.ws.LanWebSocketServer, connectionId: String) {
                    android.util.Log.d("TransportManager", "🔌 Connection closed: $connectionId")
                }
            }
            webSocketServer?.start()
        }
        if (discoveryJob == null) {
            discoveryJob = scope.launch {
                try {
                    discoverySource.discover().collect { event ->
                        handleEvent(event)
                    }
                } catch (e: Exception) {
                    android.util.Log.e("TransportManager", "❌ Discovery job error: ${e.message}", e)
                }
            }
        }

        if (pruneJob == null && pruneInterval.isPositiveDuration() && staleThreshold.isPositiveDuration()) {
            pruneJob = scope.launch {
                while (isActive) {
                    delay(pruneInterval.toMillis())
                    pruneStale(staleThreshold)
                }
            }
        }

        // Start health check task to verify advertising is still active
        if (healthCheckJob == null) {
            healthCheckJob = scope.launch {
                while (isActive) {
                    delay(30_000) // 30 seconds
                    if (!isActive) break
                    
                    // Check if advertising should be active but isn't
                    val currentAdConfig = currentConfig
                    if (currentAdConfig != null && currentAdConfig.port > 0 && !_isAdvertising.value) {
                        android.util.Log.w("TransportManager", "⚠️ Health check: Advertising should be active but isn't. Restarting...")
                        start(config)
                    }
                    
                    // Check if WebSocket server should be running but isn't
                    val currentWsConfig = currentConfig
                    if (currentWsConfig != null && currentWsConfig.port > 0 && webSocketServer == null) {
                        android.util.Log.w("TransportManager", "⚠️ Health check: WebSocket server should be running but isn't. Restarting...")
                        start(currentWsConfig)
                    }
                }
            }
        }
    }

    fun stop() {
        discoveryJob?.cancel()
        discoveryJob = null
        pruneJob?.cancel()
        pruneJob = null
        healthCheckJob?.cancel()
        healthCheckJob = null
        stopConnectionSupervisor()
        if (_isAdvertising.value) {
            registrationController.stop()
            _isAdvertising.value = false
        }
        webSocketServer?.stop()
        webSocketServer = null
        synchronized(stateLock) {
            peersByService.clear()
            lastSeenByService.clear()
            publishStateLocked()
        }
    }

    fun updateAdvertisement(
        serviceName: String? = null,
        port: Int? = null,
        fingerprint: String? = null,
        version: String? = null,
        protocols: List<String>? = null
    ) {
        val existing = currentConfig ?: return
        val updated = existing.copy(
            serviceName = serviceName ?: existing.serviceName,
            port = port ?: existing.port,
            fingerprint = fingerprint ?: existing.fingerprint,
            version = version ?: existing.version,
            protocols = protocols ?: existing.protocols
        )
        currentConfig = updated
        if (_isAdvertising.value) {
            registrationController.stop()
            registrationController.start(updated)
            _isAdvertising.value = true
        }
    }

    /**
     * Restart LAN services when network changes to update IP address
     * This ensures Bonjour/NSD service and WebSocket server rebind to new IP
     */
    fun restartForNetworkChange() {
        val config = currentConfig ?: return
        android.util.Log.d("TransportManager", "🌐 Network changed - restarting LAN services to update IP address")
        
        // Stop current services
        if (_isAdvertising.value) {
            registrationController.stop()
            _isAdvertising.value = false
        }
        webSocketServer?.stop()
        webSocketServer = null
        
        // Restart with same configuration (will bind to new IP)
        start(config)
    }

    fun currentPeers(): List<DiscoveredPeer> = peers.value

    fun lastSeen(serviceName: String): Instant? = _lastSeen.value[serviceName]

    fun lastSuccessfulTransport(peer: String): ActiveTransport? =
        lastSuccessfulTransport.value[peer]

    fun pruneStale(olderThan: Duration): List<DiscoveredPeer> {
        require(!olderThan.isNegative && !olderThan.isZero) { "Interval must be positive" }
        val threshold = clock.instant().minus(olderThan)
        val removed = mutableListOf<DiscoveredPeer>()
        synchronized(stateLock) {
            val iterator = peersByService.entries.iterator()
            while (iterator.hasNext()) {
                val entry = iterator.next()
                if (entry.value.lastSeen.isBefore(threshold)) {
                    iterator.remove()
                    lastSeenByService.remove(entry.key)
                    removed += entry.value
                }
            }
            if (removed.isNotEmpty()) {
                publishStateLocked()
            }
        }
        return removed
    }
    

    suspend fun connect(
        lanDialer: suspend () -> LanDialResult,
        cloudDialer: suspend () -> Boolean,
        fallbackTimeout: Duration = Duration.ofSeconds(3),
        peerServiceName: String? = null
    ): ConnectionState {
        require(!fallbackTimeout.isNegative && !fallbackTimeout.isZero) { "Timeout must be positive" }
        _connectionState.value = ConnectionState.ConnectingLan
        val lanAttempt: LanDialResult? = try {
            withTimeoutOrNull(fallbackTimeout.toMillis()) {
                try {
                    lanDialer()
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (throwable: Throwable) {
                    LanDialResult.Failure(FallbackReason.Unknown, throwable)
                }
            }
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (throwable: Throwable) {
            LanDialResult.Failure(FallbackReason.Unknown, throwable)
        }

        val lanResult = lanAttempt ?: LanDialResult.Failure(FallbackReason.LanTimeout, null)

        return when (lanResult) {
            LanDialResult.Success -> {
                _connectionState.value = ConnectionState.ConnectedLan
                updateLastSuccessfulTransport(peerServiceName, ActiveTransport.LAN)
                ConnectionState.ConnectedLan
            }
            is LanDialResult.Failure -> {
                recordFallback(lanResult.reason, lanResult.throwable)
                _connectionState.value = ConnectionState.ConnectingCloud
                val cloudSuccess = runCatching { cloudDialer() }.getOrDefault(false)
                _connectionState.value = if (cloudSuccess) {
                    updateLastSuccessfulTransport(peerServiceName, ActiveTransport.CLOUD)
                    ConnectionState.ConnectedCloud
                } else {
                    ConnectionState.Error
                }
                _connectionState.value
            }
        }
    }

    fun startConnectionSupervisor(
        peerServiceName: String?,
        lanDialer: suspend () -> LanDialResult,
        cloudDialer: suspend () -> Boolean,
        sendHeartbeat: suspend () -> Boolean,
        awaitAck: suspend () -> Boolean,
        networkChanges: kotlinx.coroutines.flow.Flow<Unit> = emptyFlow(),
        config: ConnectionSupervisorConfig = ConnectionSupervisorConfig()
    ) {
        stopConnectionSupervisor()
        connectionJob = scope.launch {
            networkSignalJob = launch {
                networkChanges.collect {
                    networkChangeDetected.set(true)
                }
            }
            superviseConnection(
                peerServiceName = peerServiceName,
                lanDialer = lanDialer,
                cloudDialer = cloudDialer,
                sendHeartbeat = sendHeartbeat,
                awaitAck = awaitAck,
                config = config
            )
        }
    }

    fun requestReconnect() {
        manualRetryRequested.set(true)
    }

    fun notifyNetworkChange() {
        networkChangeDetected.set(true)
    }

    fun stopConnectionSupervisor() {
        connectionJob?.cancel()
        connectionJob = null
        networkSignalJob?.cancel()
        networkSignalJob = null
        manualRetryRequested.set(false)
        networkChangeDetected.set(false)
        _connectionState.value = ConnectionState.Disconnected
    }

    suspend fun shutdown(gracefulShutdown: suspend () -> Unit) {
        gracefulShutdown()
        stopConnectionSupervisor()
    }

    private fun handleEvent(event: LanDiscoveryEvent) {
        when (event) {
            is LanDiscoveryEvent.Added -> addPeer(event.peer)
            is LanDiscoveryEvent.Removed -> removePeer(event.serviceName)
        }
    }

    /**
     * Set the LanPeerConnectionManager to sync peer connections when peers are discovered/removed.
     * Called during DI setup.
     */
    fun setLanPeerConnectionManager(manager: com.hypo.clipboard.transport.ws.LanPeerConnectionManager) {
        lanPeerConnectionManager = manager
    }
    
    /**
     * Get the LanPeerConnectionManager instance.
     * Returns null if not set (should be set during DI setup).
     */
    fun getLanPeerConnectionManager(): com.hypo.clipboard.transport.ws.LanPeerConnectionManager? {
        return lanPeerConnectionManager
    }
    
    fun addPeer(peer: DiscoveredPeer) {
        // Cancel any pending removal job if peer is rediscovered
        val pendingRemoval = synchronized(stateLock) { pendingPeerRemovalJobs.remove(peer.serviceName) }
        val existingPeer = synchronized(stateLock) { peersByService[peer.serviceName] }
        val ipChanged = existingPeer != null && existingPeer.host != peer.host
        
        if (pendingRemoval != null) {
            android.util.Log.d("TransportManager", "✅ Peer ${peer.serviceName} rediscovered (was offline, now online)")
        }
        if (ipChanged) {
            android.util.Log.d("TransportManager", "🔄 Peer ${peer.serviceName} IP changed: ${existingPeer?.host} -> ${peer.host}")
        }
        
        synchronized(stateLock) {
            peersByService[peer.serviceName] = peer
            lastSeenByService[peer.serviceName] = peer.lastSeen
            publishStateLocked()
        }
        
        // Sync peer connections (event-driven: create connection for newly discovered peer)
        scope.launch {
            lanPeerConnectionManager?.syncPeerConnections()
        }
    }

    fun removePeer(serviceName: String) {
        // Peer removal is handled by ConnectionStatusProber based on network connectivity
        // and discovery status. We don't remove peers here to avoid race conditions.
        // ConnectionStatusProber will update peer status based on network state and discovery.
        android.util.Log.d("TransportManager", "📴 Peer $serviceName reported as lost (status will be updated by ConnectionStatusProber)")
        
        // Cancel any pending removal job if peer is rediscovered
        val pendingRemoval = synchronized(stateLock) { pendingPeerRemovalJobs.remove(serviceName) }
        pendingRemoval?.cancel()
        
        // Sync peer connections (event-driven: remove connection for peer that's no longer discovered)
        scope.launch {
            lanPeerConnectionManager?.syncPeerConnections()
        }
    }

    fun forgetPairedDevice(deviceId: String) {
        clearPersistedTransportStatus(deviceId)
        // Also clear device name
        prefs?.edit()?.remove("device_name_$deviceId")?.apply()
        _lastSuccessfulTransport.update { current ->
            val updated = HashMap(current)
            updated.remove(deviceId)
            updated
        }
        android.util.Log.d("TransportManager", "🗑️ Forgot paired device: $deviceId")
    }

    private fun publishStateLocked() {
        // Deduplicate peers by device_id - keep only the most recent peer for each device_id
        val peersByDeviceId = mutableMapOf<String, DiscoveredPeer>()
        for (peer in peersByService.values) {
            val deviceId = peer.attributes["device_id"] ?: peer.serviceName
            val existing = peersByDeviceId[deviceId]
            if (existing == null || peer.lastSeen.isAfter(existing.lastSeen)) {
                peersByDeviceId[deviceId] = peer
            }
        }
        val deduplicatedPeers = peersByDeviceId.values.sortedByDescending { it.lastSeen }
        if (deduplicatedPeers.size < peersByService.size) {
            android.util.Log.d("TransportManager", "🔍 Deduplicated peers: ${peersByService.size} -> ${deduplicatedPeers.size} (removed ${peersByService.size - deduplicatedPeers.size} duplicates by device_id)")
        }
        _peers.value = deduplicatedPeers
        _lastSeen.value = HashMap(lastSeenByService)
    }

    private fun recordFallback(reason: FallbackReason, error: Throwable?) {
        val metadata = buildMap {
            put("reason", reason.code)
            error?.message?.let { put("error", it) }
        }
        analytics.record(
            TransportAnalyticsEvent.Fallback(
                reason = reason,
                metadata = metadata,
                occurredAt = clock.instant()
            )
        )
    }

    private suspend fun superviseConnection(
        peerServiceName: String?,
        lanDialer: suspend () -> LanDialResult,
        cloudDialer: suspend () -> Boolean,
        sendHeartbeat: suspend () -> Boolean,
        awaitAck: suspend () -> Boolean,
        config: ConnectionSupervisorConfig
    ) {
        var attempts = 0
        while (scope.isActive) {
            val state = connect(
                lanDialer = lanDialer,
                cloudDialer = cloudDialer,
                fallbackTimeout = config.fallbackTimeout,
                peerServiceName = peerServiceName
            )
            when (state) {
                ConnectionState.ConnectedLan,
                ConnectionState.ConnectedCloud -> {
                    attempts = 0
                    when (monitorConnection(
                        sendHeartbeat = sendHeartbeat,
                        awaitAck = awaitAck,
                        config = config
                    )) {
                        MonitorResult.GracefulStop -> {
                            _connectionState.value = ConnectionState.Disconnected
                            return
                        }
                        MonitorResult.ManualRetry,
                        MonitorResult.NetworkChange -> {
                            manualRetryRequested.set(false)
                            networkChangeDetected.set(false)
                            continue
                        }
                        MonitorResult.HeartbeatFailure,
                        MonitorResult.AckTimeout -> {
                            manualRetryRequested.set(false)
                            networkChangeDetected.set(false)
                            attempts += 1
                            if (attempts >= config.maxAttempts) {
                                _connectionState.value = ConnectionState.Error
                                return
                            }
                            val backoff = jitteredBackoff(attempts, config)
                            if (waitForBackoff(backoff)) {
                                attempts = 0
                                continue
                            }
                        }
                    }
                }
                ConnectionState.Error -> {
                    attempts += 1
                    if (attempts >= config.maxAttempts) {
                        _connectionState.value = ConnectionState.Error
                        return
                    }
                    val backoff = jitteredBackoff(attempts, config)
                    if (waitForBackoff(backoff)) {
                        attempts = 0
                        continue
                    }
                }
                else -> {
                    // Keep attempting in other states.
                    attempts += 1
                    if (attempts >= config.maxAttempts) {
                        _connectionState.value = ConnectionState.Error
                        return
                    }
                    val backoff = jitteredBackoff(attempts, config)
                    if (waitForBackoff(backoff)) {
                        attempts = 0
                        continue
                    }
                }
            }
        }
    }

    private suspend fun waitForBackoff(duration: Duration): Boolean {
        var remaining = duration.toMillis()
        while (remaining > 0 && scope.isActive) {
            if (manualRetryRequested.getAndSet(false)) {
                return true
            }
            if (networkChangeDetected.getAndSet(false)) {
                return true
            }
            val step = min(remaining, 100L)
            delay(step)
            remaining -= step
        }
        return false
    }

    private suspend fun monitorConnection(
        sendHeartbeat: suspend () -> Boolean,
        awaitAck: suspend () -> Boolean,
        config: ConnectionSupervisorConfig
    ): MonitorResult {
        while (scope.isActive) {
            delay(config.heartbeatInterval.toMillis())
            if (manualRetryRequested.getAndSet(false)) {
                return MonitorResult.ManualRetry
            }
            if (networkChangeDetected.getAndSet(false)) {
                return MonitorResult.NetworkChange
            }
            val heartbeatSuccess = runCatching { sendHeartbeat() }.getOrDefault(false)
            if (!heartbeatSuccess) {
                return MonitorResult.HeartbeatFailure
            }
            val ackSuccess = withTimeoutOrNull(config.ackTimeout.toMillis()) {
                runCatching { awaitAck() }.getOrDefault(false)
            } ?: false
            if (!ackSuccess) {
                return MonitorResult.AckTimeout
            }
        }
        return MonitorResult.GracefulStop
    }

    private fun jitteredBackoff(attempt: Int, config: ConnectionSupervisorConfig): Duration {
        val exponent = maxOf(attempt - 1, 0)
        val base = config.initialBackoff.multipliedBy(1L shl exponent)
        val capped = min(base.toMillis(), config.maxBackoff.toMillis())
        val jitterFactor = 1 + if (config.jitterRatio > 0) {
            Random.nextDouble(-config.jitterRatio, config.jitterRatio)
        } else {
            0.0
        }
        val jittered = (capped * jitterFactor).toLong().coerceAtLeast(0)
        return Duration.ofMillis(jittered)
    }

    private fun updateLastSuccessfulTransport(peer: String?, transport: ActiveTransport) {
        if (peer == null) return
        persistTransportStatus(peer, transport)
        _lastSuccessfulTransport.update { current ->
            val updated = HashMap(current)
            updated[peer] = transport
            updated
        }
    }
    
    /**
     * Mark a device as successfully connected via a specific transport.
     * This is useful after pairing when a WebSocket connection is already established.
     */
    fun markDeviceConnected(deviceId: String, transport: ActiveTransport) {
        updateLastSuccessfulTransport(deviceId, transport)
    }
    
    /**
     * Get set of device IDs that have active LAN WebSocket connections.
     */
    fun getActiveLanConnections(): Set<String> {
        return lanPeerConnectionManager?.getActiveLanConnections() ?: emptySet()
    }
    
    /**
     * Close all LAN connections (for screen-off optimization).
     */
    suspend fun closeAllLanConnections() {
        android.util.Log.d("TransportManager", "🔌 Closing all LAN connections (screen-off)")
        lanPeerConnectionManager?.closeAllConnections()
    }
    
    /**
     * Reconnect all LAN connections (for screen-on optimization).
     */
    suspend fun reconnectAllLanConnections() {
        android.util.Log.d("TransportManager", "🔄 Reconnecting all LAN connections (screen-on)")
        lanPeerConnectionManager?.reconnectAllConnections()
    }
    
    fun setPairingChallengeHandler(handler: (suspend (String) -> String?)) {
        onPairingChallenge = handler
    }
    
    fun setIncomingClipboardHandler(handler: (com.hypo.clipboard.sync.SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit) {
        onIncomingClipboard = handler
    }
    
    fun sendPairingAck(ackJson: String, to: String): Boolean {
        return webSocketServer?.sendPairingAck(ackJson, to) ?: false
    }

    companion object {
        const val DEFAULT_PORT = 7010
        const val DEFAULT_FINGERPRINT = "uninitialized"
        val DEFAULT_PROTOCOLS: List<String> = listOf("ws+tls")
    }

    private fun Duration.isPositiveDuration(): Boolean = !isZero && !isNegative
}

sealed interface LanDialResult {
    data object Success : LanDialResult
    data class Failure(val reason: FallbackReason, val throwable: Throwable?) : LanDialResult
}

enum class ConnectionState {
    Disconnected,  // Renamed from Idle for clarity - means not connected
    ConnectingLan,
    ConnectedLan,
    ConnectingCloud,
    ConnectedCloud,
    Error
}

enum class ActiveTransport {
    LAN,
    CLOUD
}

data class ConnectionSupervisorConfig(
    val fallbackTimeout: Duration = Duration.ofSeconds(3),
    val heartbeatInterval: Duration = Duration.ofSeconds(30),
    val ackTimeout: Duration = Duration.ofSeconds(5),
    val initialBackoff: Duration = Duration.ofSeconds(2),
    val maxBackoff: Duration = Duration.ofSeconds(60),
    val jitterRatio: Double = 0.2,
    val maxAttempts: Int = 5
)

private enum class MonitorResult {
    ManualRetry,
    NetworkChange,
    HeartbeatFailure,
    AckTimeout,
    GracefulStop
}
