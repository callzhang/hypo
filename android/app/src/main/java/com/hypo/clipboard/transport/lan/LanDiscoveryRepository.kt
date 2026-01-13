package com.hypo.clipboard.transport.lan

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.hypo.clipboard.util.MiuiAdapter
import com.hypo.clipboard.sync.DeviceIdentity
import java.net.InetAddress
import java.net.NetworkInterface
import java.time.Clock

class LanDiscoveryRepository(
    context: Context,
    private val nsdManager: NsdManager,
    private val wifiManager: WifiManager,
    private val deviceIdentity: DeviceIdentity,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: Clock = Clock.systemUTC(),
    private val networkEvents: Flow<Unit>? = null,
    private val multicastLockFactory: (() -> MulticastLockHandle)? = null
): LanDiscoverySource {
    private val applicationContext = context.applicationContext
    private val discoveryMutex = Mutex()
    @Volatile
    private var isDiscoveryActive = false

    override fun discover(serviceType: String): Flow<LanDiscoveryEvent> = callbackFlow {
        val multicastLock = (multicastLockFactory ?: { createMulticastLock() }).invoke().also { it.acquire() }
        var miuiRestartJob: Job?

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String?) {
                android.util.Log.v("LanDiscoveryRepository", "✅ Discovery started for type: $regType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                // Log own IPs before resolution to help debug why NSD resolves to wrong IP
                val ownIPsBeforeResolve = getLocalIPAddresses() // Will log to debug internally
                android.util.Log.v("LanDiscoveryRepository", "🔍 Found: ${serviceInfo.serviceName} (${serviceInfo.serviceType}) | OwnIPs: [${ownIPsBeforeResolve.joinToString()}]")
                @Suppress("DEPRECATION")
                nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        android.util.Log.w("LanDiscoveryRepository", "❌ Failed to resolve service ${serviceInfo.serviceName}: errorCode=$errorCode")
                        // No-op: discovery will continue on subsequent callbacks.
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        @Suppress("DEPRECATION")
                        val resolvedIP = serviceInfo.host?.hostAddress
                        @Suppress("DEPRECATION")
                        val resolvedHostname = serviceInfo.host?.hostName
                        val ownIPs = getLocalIPAddresses()
                        
                        // Extract attributes to check device_id
                        val attributes = serviceInfo.attributes.mapValues { entry ->
                            entry.value?.let { String(it) } ?: ""
                        }
                        val deviceId = attributes["device_id"] ?: ""
                        
                        // Log comprehensive resolution details for debugging
                        @Suppress("DEPRECATION")
                        val addressBytes = serviceInfo.host?.address?.contentToString() ?: "null"
                        @Suppress("DEPRECATION")
                        val canonicalName = serviceInfo.host?.canonicalHostName ?: "null"
                        val isOwnIP = resolvedIP != null && resolvedIP in ownIPs
                        val isSelfDevice = deviceId == deviceIdentity.deviceId || 
                                         serviceInfo.serviceName.startsWith(deviceIdentity.deviceId) ||
                                         (deviceId.isEmpty() && serviceInfo.serviceName.contains(deviceIdentity.deviceId))
                        
                        android.util.Log.v("LanDiscoveryRepository", 
                            "✅ Service resolved: ${serviceInfo.serviceName} -> IP=$resolvedIP:$serviceInfo.port, " +
                            "hostname=$resolvedHostname, canonical=$canonicalName, addressBytes=$addressBytes, " +
                            "ownIPs=[${ownIPs.joinToString()}], isOwnIP=$isOwnIP, deviceId=$deviceId, isSelfDevice=$isSelfDevice")
                        
                        // Validate that resolved service is not our own service
                        // Check both IP address (Android NSD bug) and device_id (self-service detection)
                        if (isOwnIP) {
                            android.util.Log.v("LanDiscoveryRepository", 
                                "⚠️ Rejecting service ${serviceInfo.serviceName}: resolved IP $resolvedIP matches own IP " +
                                "(ownIPs=[${ownIPs.joinToString()}]) - NSD resolution bug, waiting for correct resolution")
                            return // Don't process this peer - wait for correct resolution
                        }
                        
                        if (isSelfDevice) {
                            android.util.Log.v("LanDiscoveryRepository", 
                                "⏭️ Rejecting service ${serviceInfo.serviceName}: device_id $deviceId matches own device_id " +
                                "(${deviceIdentity.deviceId}) - this is our own published service")
                            return // Don't process our own service
                        }
                        
                        toPeer(serviceInfo)?.let { peer ->
                            trySend(LanDiscoveryEvent.Added(peer))
                        } ?: run {
                            android.util.Log.w("LanDiscoveryRepository", "⚠️ Failed to convert serviceInfo to DiscoveredPeer")
                        }
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                trySend(LanDiscoveryEvent.Removed(serviceInfo.serviceName))
            }

            override fun onDiscoveryStopped(serviceType: String?) {}

            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                android.util.Log.e("LanDiscoveryRepository", "❌ Failed to start discovery for $serviceType: errorCode=$errorCode")
                val errorMsg = when (errorCode) {
                    NsdManager.FAILURE_INTERNAL_ERROR -> "Internal error"
                    NsdManager.FAILURE_ALREADY_ACTIVE -> "Already active"
                    NsdManager.FAILURE_MAX_LIMIT -> "Max limit reached"
                    else -> "Unknown error ($errorCode)"
                }
                android.util.Log.e("LanDiscoveryRepository", "   Error: $errorMsg")
                trySend(LanDiscoveryEvent.Removed(serviceType ?: ""))
            }

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}
        }

        val networkJob = launch {
            (networkEvents ?: defaultNetworkEvents()).collect {
                restartDiscovery(serviceType, listener)
            }
        }
        
        // On MIUI/HyperOS, schedule periodic NSD restart to work around multicast throttling
        miuiRestartJob = if (MiuiAdapter.isMiuiOrHyperOS()) {
            val restartInterval = MiuiAdapter.getRecommendedNsdRestartInterval()
            if (restartInterval != null) {
                launch {
                    while (coroutineContext.isActive) {
                        delay(restartInterval)
                        if (coroutineContext.isActive && isDiscoveryActive) {
                            android.util.Log.v("LanDiscoveryRepository", "🔄 Periodic NSD restart (MIUI/HyperOS workaround)")
                            restartDiscovery(serviceType, listener)
                        }
                    }
                }
            } else null
        } else null

        startDiscovery(serviceType, listener)

        awaitClose {
            networkJob.cancel()
            miuiRestartJob?.cancel()
            stopDiscovery(listener)
            if (multicastLock.isHeld) {
                multicastLock.release()
            }
        }
    }.flowOn(dispatcher)

    private suspend fun startDiscovery(
        serviceType: String,
        listener: NsdManager.DiscoveryListener
    ) {
        discoveryMutex.withLock {
            if (!isDiscoveryActive) {
                runCatching {
                    nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
                    isDiscoveryActive = true
                }
            }
        }
    }

    private fun stopDiscovery(listener: NsdManager.DiscoveryListener) {
        if (isDiscoveryActive) {
            runCatching {
                nsdManager.stopServiceDiscovery(listener)
                isDiscoveryActive = false
            }
        }
    }

    private suspend fun restartDiscovery(
        serviceType: String,
        listener: NsdManager.DiscoveryListener
    ) {
        discoveryMutex.withLock {
            if (isDiscoveryActive) {
                runCatching {
                    nsdManager.stopServiceDiscovery(listener)
                    isDiscoveryActive = false
                }
                // Small delay to let Android NsdManager clean up the listener
                kotlinx.coroutines.delay(100)
            }
            runCatching {
            @Suppress("DEPRECATION")
            nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
                isDiscoveryActive = true
            }
        }
    }

    private fun toPeer(serviceInfo: NsdServiceInfo): DiscoveredPeer? {
        @Suppress("DEPRECATION")
        val host = serviceInfo.host?.asString() ?: return null
        val attributes = serviceInfo.attributes.mapValues { entry ->
            entry.value?.let { String(it) } ?: ""
        }
        val fingerprint = attributes[FINGERPRINT_KEY]
        return DiscoveredPeer(
            serviceName = serviceInfo.serviceName,
            host = host,
            port = serviceInfo.port,
            fingerprint = fingerprint,
            attributes = attributes,
            lastSeen = clock.instant()
        )
    }

    private fun InetAddress.asString(): String = hostAddress ?: hostName

    /**
     * Get all local IP addresses for this device to filter out self-resolved services
     */
    private fun getLocalIPAddresses(): Set<String> {
        val ips = mutableSetOf<String>()
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                val addresses = networkInterface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    if (!address.isLoopbackAddress && address is java.net.Inet4Address) {
                        val ip = address.hostAddress
                        if (ip != null) {
                            ips.add(ip)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            android.util.Log.w("LanDiscoveryRepository", "⚠️ Failed to get local IP addresses: ${e.message}")
        }
        return ips
    }

    private fun defaultNetworkEvents(): Flow<Unit> = callbackFlow {
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: android.content.Intent?) {
                trySend(Unit).isSuccess
            }
        }
        applicationContext.registerReceiver(
            receiver,
            android.content.IntentFilter(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        )
        awaitClose { applicationContext.unregisterReceiver(receiver) }
    }

    private fun createMulticastLock(): MulticastLockHandle {
        val lock = wifiManager.createMulticastLock(MULTICAST_LOCK_TAG).apply {
            setReferenceCounted(true)
        }
        return object : MulticastLockHandle {
            override val isHeld: Boolean
                get() = lock.isHeld

            override fun acquire() {
                lock.acquire()
            }

            override fun release() {
                lock.release()
            }
        }
    }

    private companion object {
        const val MULTICAST_LOCK_TAG = "HypoLanDiscovery"
        const val FINGERPRINT_KEY = "fingerprint_sha256"
    }

    interface MulticastLockHandle {
        val isHeld: Boolean
        fun acquire()
        fun release()
    }
}

interface LanDiscoverySource {
    fun discover(serviceType: String = SERVICE_TYPE): Flow<LanDiscoveryEvent>
}
