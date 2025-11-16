package com.hypo.clipboard.transport

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
    private val stateLock = Any()
    private val peersByService = mutableMapOf<String, DiscoveredPeer>()
    private val lastSeenByService = mutableMapOf<String, Instant>()

    private val _peers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    private val _lastSeen = MutableStateFlow<Map<String, Instant>>(emptyMap())
    private val _isAdvertising = MutableStateFlow(false)
    private val _connectionState = MutableStateFlow(ConnectionState.Idle)
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
        android.util.Log.d("TransportManager", "💾 Persisting transport status: device=$deviceId, transport=$transport")
        val key = "transport_$deviceId"
        try {
            val editor = prefs?.edit()
            if (editor == null) {
                android.util.Log.e("TransportManager", "❌ Failed to get SharedPreferences editor")
                return
            }
            editor.putString(key, transport.name)
            val success = editor.commit()
            if (success) {
                android.util.Log.d("TransportManager", "✅ Transport status persisted successfully: key=$key, value=${transport.name}")
                // Verify it was saved immediately
                val saved = prefs?.getString(key, null)
                android.util.Log.d("TransportManager", "🔍 Verification: saved value=$saved")
                // Also verify all entries
                val allEntries = prefs?.all
                android.util.Log.d("TransportManager", "🔍 All SharedPreferences entries: ${allEntries?.keys}")
                // Update the StateFlow to ensure it reflects the persisted value
                _lastSuccessfulTransport.update { current ->
                    val updated = HashMap(current)
                    updated[deviceId] = transport
                    updated
                }
            } else {
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
        val key = "device_name_$deviceId"
        prefs?.edit()?.putString(key, deviceName)?.commit()
        android.util.Log.d("TransportManager", "💾 Persisted device name: device=$deviceId, name=$deviceName")
    }
    
    fun getDeviceName(deviceId: String): String? {
        if (prefs == null) return null
        val key = "device_name_$deviceId"
        return prefs?.getString(key, null)
    }
    
    private fun clearPersistedTransportStatus(deviceId: String) {
        prefs?.edit()?.remove("transport_$deviceId")?.apply()
    }

    private var discoveryJob: Job? = null
    private var pruneJob: Job? = null
    private var connectionJob: Job? = null
    private var networkSignalJob: Job? = null
    private var currentConfig: LanRegistrationConfig? = null
    private val manualRetryRequested = AtomicBoolean(false)
    private val networkChangeDetected = AtomicBoolean(false)

    val peers: StateFlow<List<DiscoveredPeer>> = _peers.asStateFlow()
    val isAdvertising: StateFlow<Boolean> = _isAdvertising.asStateFlow()
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()
    val lastSuccessfulTransport: StateFlow<Map<String, ActiveTransport>> =
        _lastSuccessfulTransport.asStateFlow()

    fun start(config: LanRegistrationConfig) {
        currentConfig = config
        registrationController.start(config)
        _isAdvertising.value = true
        if (discoveryJob == null) {
            discoveryJob = scope.launch {
                discoverySource.discover().collect { event ->
                    handleEvent(event)
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
    }

    fun stop() {
        discoveryJob?.cancel()
        discoveryJob = null
        pruneJob?.cancel()
        pruneJob = null
        stopConnectionSupervisor()
        if (_isAdvertising.value) {
            registrationController.stop()
            _isAdvertising.value = false
        }
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
        _connectionState.value = ConnectionState.Idle
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

    fun addPeer(peer: DiscoveredPeer) {
        synchronized(stateLock) {
            peersByService[peer.serviceName] = peer
            lastSeenByService[peer.serviceName] = peer.lastSeen
            publishStateLocked()
        }
    }

    fun removePeer(serviceName: String) {
        synchronized(stateLock) {
            val removed = peersByService.remove(serviceName)
            if (removed != null) {
                lastSeenByService.remove(serviceName)
                publishStateLocked()
            }
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
        _peers.value = peersByService.values.sortedByDescending { it.lastSeen }
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
                    when (val monitorResult = monitorConnection(
                        sendHeartbeat = sendHeartbeat,
                        awaitAck = awaitAck,
                        config = config
                    )) {
                        MonitorResult.GracefulStop -> {
                            _connectionState.value = ConnectionState.Idle
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
        android.util.Log.d("TransportManager", "🔵 markDeviceConnected called: deviceId=$deviceId, transport=$transport")
        updateLastSuccessfulTransport(deviceId, transport)
        android.util.Log.d("TransportManager", "🔵 markDeviceConnected completed")
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
    Idle,
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
