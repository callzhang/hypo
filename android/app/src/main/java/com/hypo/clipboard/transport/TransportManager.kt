package com.hypo.clipboard.transport

import com.hypo.clipboard.transport.lan.DiscoveredPeer
import com.hypo.clipboard.transport.lan.LanDiscoveryEvent
import com.hypo.clipboard.transport.lan.LanDiscoverySource
import com.hypo.clipboard.transport.lan.LanRegistrationConfig
import com.hypo.clipboard.transport.lan.LanRegistrationController
import java.time.Clock
import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.collections.buildMap

class TransportManager(
    private val discoverySource: LanDiscoverySource,
    private val registrationController: LanRegistrationController,
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

    private var discoveryJob: Job? = null
    private var pruneJob: Job? = null
    private var currentConfig: LanRegistrationConfig? = null

    val peers: StateFlow<List<DiscoveredPeer>> = _peers.asStateFlow()
    val isAdvertising: StateFlow<Boolean> = _isAdvertising.asStateFlow()
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

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
        fallbackTimeout: Duration = Duration.ofSeconds(3)
    ): ConnectionState {
        require(!fallbackTimeout.isNegative && !fallbackTimeout.isZero) { "Timeout must be positive" }
        _connectionState.value = ConnectionState.ConnectingLan
        val lanResult = withTimeoutOrNull(fallbackTimeout.toMillis()) {
            lanDialer()
        } ?: LanDialResult.Failure(FallbackReason.LanTimeout, null)

        return when (lanResult) {
            LanDialResult.Success -> {
                _connectionState.value = ConnectionState.ConnectedLan
                ConnectionState.ConnectedLan
            }
            is LanDialResult.Failure -> {
                recordFallback(lanResult.reason, lanResult.throwable)
                _connectionState.value = ConnectionState.ConnectingCloud
                val cloudSuccess = runCatching { cloudDialer() }.getOrDefault(false)
                _connectionState.value = if (cloudSuccess) {
                    ConnectionState.ConnectedCloud
                } else {
                    ConnectionState.Error
                }
                _connectionState.value
            }
        }
    }

    private fun handleEvent(event: LanDiscoveryEvent) {
        when (event) {
            is LanDiscoveryEvent.Added -> addPeer(event.peer)
            is LanDiscoveryEvent.Removed -> removePeer(event.serviceName)
        }
    }

    private fun addPeer(peer: DiscoveredPeer) {
        synchronized(stateLock) {
            peersByService[peer.serviceName] = peer
            lastSeenByService[peer.serviceName] = peer.lastSeen
            publishStateLocked()
        }
    }

    private fun removePeer(serviceName: String) {
        synchronized(stateLock) {
            val removed = peersByService.remove(serviceName)
            if (removed != null) {
                lastSeenByService.remove(serviceName)
                publishStateLocked()
            }
        }
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
