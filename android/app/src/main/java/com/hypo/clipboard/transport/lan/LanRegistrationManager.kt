package com.hypo.clipboard.transport.lan

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Duration
import kotlin.math.min

class LanRegistrationManager(
    context: Context,
    private val nsdManager: NsdManager,
    private val wifiManager: WifiManager,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + dispatcher),
    private val initialBackoff: Duration = Duration.ofSeconds(1),
    private val maxBackoff: Duration = Duration.ofMinutes(5)
): LanRegistrationController {
    private val applicationContext = context.applicationContext
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var connectivityReceiver: BroadcastReceiver? = null
    private var retryJob: Job? = null
    private var attempts = 0
    private var currentConfig: LanRegistrationConfig? = null
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null

    override fun start(config: LanRegistrationConfig) {
        android.util.Log.d("LanRegistrationManager", "🚀 Starting service registration: serviceName=${config.serviceName}, port=${config.port}, serviceType=${config.serviceType}")
        currentConfig = config
        registerReceiverIfNeeded()
        acquireMulticastLock()
        attempts = 0
        registerService(config)
    }
    
    private fun acquireMulticastLock() {
        if (multicastLock == null) {
            multicastLock = wifiManager.createMulticastLock("HypoLanRegistration").apply {
                setReferenceCounted(true)
            }
        }
        if (multicastLock?.isHeld != true) {
            multicastLock?.acquire()
            android.util.Log.d("LanRegistrationManager", "🔒 Multicast lock acquired")
        }
    }
    
    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) {
                lock.release()
                android.util.Log.d("LanRegistrationManager", "🔓 Multicast lock released")
            }
        }
    }

    override fun stop() {
        retryJob?.cancel()
        retryJob = null
        currentConfig = null
        registrationListener?.let { listener ->
            runCatching { nsdManager.unregisterService(listener) }
        }
        registrationListener = null
        connectivityReceiver?.let { receiver ->
            applicationContext.unregisterReceiver(receiver)
        }
        connectivityReceiver = null
        releaseMulticastLock()
    }

    private fun registerReceiverIfNeeded() {
        if (connectivityReceiver != null) return
        connectivityReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                android.util.Log.i("LanRegistrationManager", "🌐 Network state changed - re-registering service to update IP address")
                currentConfig?.let { config ->
                    // Unregister first to ensure clean restart with new IP
                    registrationListener?.let { listener ->
                        runCatching { nsdManager.unregisterService(listener) }
                    }
                    // Then re-register with new network configuration
                    scheduleRetry(config, immediate = true)
                }
            }
        }
        applicationContext.registerReceiver(
            connectivityReceiver,
            IntentFilter(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        )
    }

    private fun registerService(config: LanRegistrationConfig) {
        android.util.Log.d("LanRegistrationManager", "📝 Registering NSD service: serviceName=${config.serviceName}, port=${config.port}, serviceType=${config.serviceType}")
        val info = NsdServiceInfo().apply {
            serviceName = config.serviceName
            serviceType = config.serviceType
            port = config.port
            setAttribute("fingerprint_sha256", config.fingerprint)
            setAttribute("version", config.version)
            setAttribute("protocols", config.protocols.joinToString(","))
            // Add device_id attribute so devices can match discovered peers
            config.deviceId?.let { deviceId ->
                setAttribute("device_id", deviceId)
                android.util.Log.d("LanRegistrationManager", "📝 Added device_id attribute: $deviceId")
            }
            // Add public keys for device-agnostic pairing
            config.publicKey?.let { pubKey ->
                setAttribute("pub_key", pubKey)
                android.util.Log.d("LanRegistrationManager", "📝 Added pub_key attribute (${pubKey.length} chars)")
            }
            config.signingPublicKey?.let { signingKey ->
                setAttribute("signing_pub_key", signingKey)
                android.util.Log.d("LanRegistrationManager", "📝 Added signing_pub_key attribute (${signingKey.length} chars)")
            }
        }
        android.util.Log.d("LanRegistrationManager", "📝 Service info created: name=${info.serviceName}, type=${info.serviceType}, port=${info.port}")
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                android.util.Log.i("LanRegistrationManager", "✅ Service registered successfully: ${serviceInfo.serviceName}")
                attempts = 0
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                val errorMsg = when (errorCode) {
                    NsdManager.FAILURE_INTERNAL_ERROR -> "Internal error"
                    NsdManager.FAILURE_ALREADY_ACTIVE -> "Already active"
                    NsdManager.FAILURE_MAX_LIMIT -> "Max limit reached"
                    else -> "Unknown error ($errorCode)"
                }
                android.util.Log.e("LanRegistrationManager", "❌ Service registration failed: $errorMsg (code=$errorCode), serviceName=${serviceInfo.serviceName}")
                scheduleRetry(config)
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                android.util.Log.d("LanRegistrationManager", "📴 Service unregistered: ${serviceInfo.serviceName}")
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                android.util.Log.w("LanRegistrationManager", "⚠️ Service unregistration failed: errorCode=$errorCode, serviceName=${serviceInfo.serviceName}")
                scheduleRetry(config)
            }
        }
        registrationListener = listener
        scope.launch(dispatcher) {
            runCatching { 
                android.util.Log.d("LanRegistrationManager", "🔄 Calling nsdManager.registerService()...")
                nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
                android.util.Log.d("LanRegistrationManager", "✅ nsdManager.registerService() called successfully")
            }
                .onFailure { error ->
                    android.util.Log.e("LanRegistrationManager", "❌ Failed to call registerService: ${error.message}", error)
                    scheduleRetry(config)
                }
        }
    }

    private fun scheduleRetry(config: LanRegistrationConfig, immediate: Boolean = false) {
        retryJob?.cancel()
        retryJob = scope.launch(dispatcher) {
            if (!immediate) {
                delay(backoffDelayMillis())
            }
            if (currentConfig == config) {
                registerService(config)
            }
        }
    }

    private fun backoffDelayMillis(): Long {
        val attempt = attempts.coerceAtLeast(0)
        val baseMillis = initialBackoff.toMillis().coerceAtLeast(1)
        val delayMillis = baseMillis * (1L shl attempt)
        attempts = min(attempt + 1, MAX_ATTEMPTS)
        return min(delayMillis, maxBackoff.toMillis())
    }

    companion object {
        private const val MAX_ATTEMPTS = 8
    }
}

data class LanRegistrationConfig(
    val serviceName: String,
    val port: Int,
    val fingerprint: String,
    val version: String,
    val protocols: List<String>,
    val serviceType: String = SERVICE_TYPE,
    val deviceId: String? = null,
    val publicKey: String? = null, // Base64-encoded Curve25519 public key for pairing
    val signingPublicKey: String? = null // Base64-encoded Ed25519 public key for signature verification
)

interface LanRegistrationController {
    fun start(config: LanRegistrationConfig)
    fun stop()
}
