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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Duration
import kotlin.math.min

class LanRegistrationManager(
    context: Context,
    private val nsdManager: NsdManager,
    private val wifiManager: WifiManager,
    private val scope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val initialBackoff: Duration = Duration.ofSeconds(1),
    private val maxBackoff: Duration = Duration.ofMinutes(5)
) {
    private val applicationContext = context.applicationContext
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var connectivityReceiver: BroadcastReceiver? = null
    private var retryJob: Job? = null
    private var attempts = 0
    private var currentConfig: LanRegistrationConfig? = null

    fun start(config: LanRegistrationConfig) {
        currentConfig = config
        registerReceiverIfNeeded()
        attempts = 0
        registerService(config)
    }

    fun stop() {
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
    }

    private fun registerReceiverIfNeeded() {
        if (connectivityReceiver != null) return
        connectivityReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                currentConfig?.let { scheduleRetry(it, immediate = true) }
            }
        }
        applicationContext.registerReceiver(
            connectivityReceiver,
            IntentFilter(WifiManager.NETWORK_STATE_CHANGED_ACTION)
        )
    }

    private fun registerService(config: LanRegistrationConfig) {
        val info = NsdServiceInfo().apply {
            serviceName = config.serviceName
            serviceType = config.serviceType
            port = config.port
            setAttribute("fingerprint_sha256", config.fingerprint)
            setAttribute("version", config.version)
            setAttribute("protocols", config.protocols.joinToString(","))
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                attempts = 0
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                scheduleRetry(config)
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                scheduleRetry(config)
            }
        }
        registrationListener = listener
        scope.launch(dispatcher) {
            runCatching { nsdManager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
                .onFailure { scheduleRetry(config) }
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
    val serviceType: String = SERVICE_TYPE
)
