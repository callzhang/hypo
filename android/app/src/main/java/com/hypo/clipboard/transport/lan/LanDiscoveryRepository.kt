package com.hypo.clipboard.transport.lan

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.InetAddress
import java.time.Clock

class LanDiscoveryRepository(
    context: Context,
    private val nsdManager: NsdManager,
    private val wifiManager: WifiManager,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: Clock = Clock.systemUTC()
) {
    private val applicationContext = context.applicationContext
    private val discoveryMutex = Mutex()

    fun discover(serviceType: String = SERVICE_TYPE): Flow<LanDiscoveryEvent> = callbackFlow {
        val multicastLock = wifiManager.createMulticastLock(MULTICAST_LOCK_TAG).apply {
            setReferenceCounted(true)
            acquire()
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String?) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        // No-op: discovery will continue on subsequent callbacks.
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        toPeer(serviceInfo)?.let { peer ->
                            trySend(LanDiscoveryEvent.Added(peer))
                        }
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                trySend(LanDiscoveryEvent.Removed(serviceInfo.serviceName))
            }

            override fun onDiscoveryStopped(serviceType: String?) {}

            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) {
                trySend(LanDiscoveryEvent.Removed(serviceType ?: ""))
            }

            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) {}
        }

        val networkReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                launch { restartDiscovery(serviceType, listener) }
            }
        }

        applicationContext.registerReceiver(
            networkReceiver,
            IntentFilter(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        )

        launch { restartDiscovery(serviceType, listener) }

        awaitClose {
            applicationContext.unregisterReceiver(networkReceiver)
            runCatching { nsdManager.stopServiceDiscovery(listener) }
            if (multicastLock.isHeld) {
                multicastLock.release()
            }
        }
    }.flowOn(dispatcher)

    private suspend fun restartDiscovery(
        serviceType: String,
        listener: NsdManager.DiscoveryListener
    ) {
        discoveryMutex.withLock {
            runCatching { nsdManager.stopServiceDiscovery(listener) }
            nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
        }
    }

    private fun toPeer(serviceInfo: NsdServiceInfo): DiscoveredPeer? {
        val host = serviceInfo.host?.asString() ?: return null
        val attributes = serviceInfo.attributes.mapValues { entry ->
            entry.value?.let { String(it) } ?: ""
        }
        val fingerprint = attributes[FINGERPRINT_KEY]
        return DiscoveredPeer(
            serviceName: serviceInfo.serviceName,
            host: host,
            port: serviceInfo.port,
            fingerprint: fingerprint,
            attributes: attributes,
            lastSeen: clock.instant()
        )
    }

    private fun InetAddress.asString(): String = hostAddress ?: hostName

    private companion object {
        const val MULTICAST_LOCK_TAG = "HypoLanDiscovery"
        const val FINGERPRINT_KEY = "fingerprint_sha256"
    }
}
