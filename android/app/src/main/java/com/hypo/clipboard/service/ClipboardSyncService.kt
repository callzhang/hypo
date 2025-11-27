package com.hypo.clipboard.service

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.hypo.clipboard.MainActivity
import com.hypo.clipboard.R
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.service.ClipboardAccessibilityService
import com.hypo.clipboard.sync.ClipboardListener
import com.hypo.clipboard.sync.ClipboardParser
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.SyncCoordinator
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.LanRegistrationConfig
import com.google.crypto.tink.subtle.X25519
import com.google.crypto.tink.subtle.Ed25519Sign
import dagger.hilt.android.AndroidEntryPoint
import android.util.Base64
import java.security.MessageDigest
import java.time.Duration
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import javax.inject.Inject

@AndroidEntryPoint
class ClipboardSyncService : Service() {

    @Inject lateinit var syncCoordinator: SyncCoordinator
    @Inject lateinit var transportManager: TransportManager
    @Inject lateinit var deviceIdentity: DeviceIdentity
    @Inject lateinit var repository: ClipboardRepository
    @Inject lateinit var incomingClipboardHandler: com.hypo.clipboard.sync.IncomingClipboardHandler
    @Inject lateinit var lanWebSocketClient: com.hypo.clipboard.transport.ws.LanWebSocketClient
    @Inject lateinit var relayWebSocketClient: com.hypo.clipboard.transport.ws.RelayWebSocketClient
    @Inject lateinit var clipboardAccessChecker: com.hypo.clipboard.sync.ClipboardAccessChecker
    @Inject lateinit var connectionStatusProber: com.hypo.clipboard.transport.ConnectionStatusProber
    @Inject lateinit var pairingHandshakeManager: com.hypo.clipboard.pairing.PairingHandshakeManager

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var listener: ClipboardListener
    private lateinit var notificationManager: NotificationManagerCompat
    private var notificationJob: Job? = null
    private var clipboardPermissionJob: Job? = null
    private var latestPreview: String? = null
    private var isPaused: Boolean = false
    private var isScreenOff: Boolean = false
    private var awaitingClipboardPermission: Boolean = false
    private var isAppInForeground: Boolean = false
    private var isAccessibilityServiceEnabled: Boolean = false
    private lateinit var screenStateReceiver: ScreenStateReceiver
    private var networkCallback: android.net.ConnectivityManager.NetworkCallback? = null
    private lateinit var connectivityManager: android.net.ConnectivityManager

    override fun onCreate() {
        super.onCreate()
        notificationManager = NotificationManagerCompat.from(this)
        createNotificationChannel()
        
        // Start foreground service immediately to keep app alive
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        val parser = ClipboardParser(
            contentResolver = contentResolver,
            onFileTooLarge = { filename, size ->
                // Show warning notification when file exceeds 10MB
                showFileTooLargeWarning(filename, size)
            }
        )
        val clipboardCallback: suspend (com.hypo.clipboard.sync.ClipboardEvent) -> Unit = { event ->
            syncCoordinator.onClipboardEvent(event)
        }
        
        listener = ClipboardListener(
            clipboardManager = clipboardManager,
            parser = parser,
            onClipboardChanged = clipboardCallback,
            scope = scope
        )

        syncCoordinator.start(scope)
        val lanConfig = buildLanRegistrationConfig()
        transportManager.start(lanConfig)
        
        // Set up pairing challenge handler for WebSocket server (incoming connections)
        transportManager.setPairingChallengeHandler { challengeJson ->
            Log.d(TAG, "📱 Received pairing challenge, handling...")
            Log.d(TAG, "   Challenge JSON length: ${challengeJson.length}")
            Log.d(TAG, "   Challenge JSON preview: ${challengeJson.take(200)}")
            try {
                // Load persistent LAN pairing private key
                val prefs = getSharedPreferences("hypo_pairing_keys", Context.MODE_PRIVATE)
                val privateKeyBase64 = prefs.getString("lan_agreement_private_key", null)
                if (privateKeyBase64 == null) {
                    Log.e(TAG, "❌ No LAN pairing private key found, cannot handle challenge")
                    Log.e(TAG, "   Available keys in prefs: ${prefs.all.keys}")
                    return@setPairingChallengeHandler null
                }
                Log.d(TAG, "   Loaded private key (base64 length: ${privateKeyBase64.length})")
                val privateKey = android.util.Base64.decode(privateKeyBase64, android.util.Base64.NO_WRAP)
                Log.d(TAG, "   Decoded private key size: ${privateKey.size} bytes")
                
                // Handle challenge and generate ACK (this is a suspend function)
                Log.d(TAG, "   Calling pairingHandshakeManager.handleChallenge...")
                val ackJson = pairingHandshakeManager.handleChallenge(challengeJson, privateKey)
                if (ackJson != null) {
                    Log.d(TAG, "✅ Generated pairing ACK (${ackJson.length} chars), sending response")
                    Log.d(TAG, "   ACK JSON preview: ${ackJson.take(200)}")
                } else {
                    Log.e(TAG, "❌ Failed to generate pairing ACK")
                }
                ackJson
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error handling pairing challenge: ${e.message}", e)
                Log.e(TAG, "   Exception type: ${e.javaClass.simpleName}")
                e.printStackTrace()
                null
            }
        }
        
        lanWebSocketClient.setIncomingClipboardHandler { envelope, origin ->
            incomingClipboardHandler.handle(envelope, origin)
        }
        relayWebSocketClient.setIncomingClipboardHandler { envelope, origin ->
            incomingClipboardHandler.handle(envelope, origin)
        }
        // Set handler for LAN WebSocket server (incoming connections from other devices)
        transportManager.setIncomingClipboardHandler { envelope, origin ->
            incomingClipboardHandler.handle(envelope, origin)
        }
        
        // Start receiving connections for both LAN and cloud
        // NOTE: relayWebSocketClient creates its own LanWebSocketClient instance,
        // so calling startReceiving() on both creates TWO separate connections.
        // Only call startReceiving() on relayWebSocketClient for cloud relay.
        // lanWebSocketClient.startReceiving() is for LAN connections only.
        lanWebSocketClient.startReceiving()  // For LAN connections
        relayWebSocketClient.startReceiving()  // For cloud relay (creates separate connection)
        ensureClipboardPermissionAndStartListener()
        observeLatestItem()
        // Ensure database latest entry matches current clipboard on startup
        ensureDatabaseMatchesCurrentClipboard()
        registerScreenStateReceiver()
        registerNetworkChangeCallback()
        connectionStatusProber.start()
        
        // Monitor app foreground state and accessibility service status
        scope.launch {
            while (isActive) {
                val wasForeground = isAppInForeground
                checkAppForegroundState()
                // Probe connections when app comes to foreground
                if (!wasForeground && isAppInForeground) {
                    connectionStatusProber.probeNow()
                }
                checkAccessibilityServiceStatus()
                delay(2_000) // Check every 2 seconds
            }
        }
    }

    override fun onDestroy() {
        notificationJob?.cancel()
        unregisterScreenStateReceiver()
        unregisterNetworkChangeCallback()
        listener.stop()
        syncCoordinator.stop()
        clipboardPermissionJob?.cancel()
        transportManager.stop()
        connectionStatusProber.cleanup()
        scope.coroutineContext.cancelChildren()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> pauseListener()
            ACTION_RESUME -> resumeListener()
            ACTION_OPEN_CLIPBOARD_SETTINGS -> openClipboardSettings()
            ACTION_OPEN_ACCESSIBILITY_SETTINGS -> openAccessibilitySettings()
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }

        // Ensure LAN advertising is running (START_STICKY restarts may drop NSD registration)
        ensureLanAdvertising()
        return START_STICKY
    }

    private fun ensureLanAdvertising() {
        // Only start if not already advertising
        if (!transportManager.isAdvertising.value) {
            val lanConfig = buildLanRegistrationConfig()
            Log.d(TAG, "🔁 ensureLanAdvertising: restarting transportManager with serviceName=${lanConfig.serviceName}")
            transportManager.start(lanConfig)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            
            // Main sync channel
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.service_notification_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = getString(R.string.service_notification_channel_description)
                setShowBadge(false)
                enableLights(false)
                enableVibration(false)
            }
            manager.createNotificationChannel(channel)
            
            // Warning channel (for file size warnings)
            val warningChannel = NotificationChannel(
                WARNING_CHANNEL_ID,
                getString(R.string.warning_notification_channel_name),
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = getString(R.string.warning_notification_channel_description)
                setShowBadge(true)
                enableLights(true)
                enableVibration(true)
            }
            manager.createNotificationChannel(warningChannel)
        }
    }

    private fun buildNotification(): Notification {
        val statusText = when {
            awaitingClipboardPermission -> getString(R.string.service_notification_status_permission)
            isPaused -> getString(R.string.service_notification_status_paused)
            !isAccessibilityServiceEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !isAppInForeground -> "Enable accessibility for background access"
            !isAppInForeground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> "Background (clipboard access limited)"
            else -> getString(R.string.service_notification_status_active)
        }
        val previewText = when {
            awaitingClipboardPermission -> getString(R.string.service_notification_permission_body)
            !isAccessibilityServiceEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !isAppInForeground -> "Enable accessibility service in Settings → Accessibility → Hypo for background clipboard access"
            !isAppInForeground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !isAccessibilityServiceEnabled -> "App must be in foreground for clipboard access on Android 10+"
            else -> latestPreview ?: getString(R.string.service_notification_text)
        }

        // Create intent to open app when notification is tapped
        val contentIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.service_notification_title))
            .setContentText(previewText)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(previewText)
                    .setSummaryText(statusText)
            )

        // Show action buttons based on state
        if (awaitingClipboardPermission) {
            builder.addAction(
                R.drawable.ic_notification,
                getString(R.string.action_grant_clipboard_access),
                pendingIntentForAction(ACTION_OPEN_CLIPBOARD_SETTINGS)
            )
        } else if (!isAccessibilityServiceEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !isAppInForeground) {
            // Show accessibility enable button when app is in background and accessibility is not enabled
            builder.addAction(
                R.drawable.ic_notification,
                getString(R.string.accessibility_enable_button),
                pendingIntentForAction(ACTION_OPEN_ACCESSIBILITY_SETTINGS)
            )
        }

        return builder.build()
    }

    private fun updateNotification() {
        try {
            val notification = buildNotification()
            notificationManager.notify(NOTIFICATION_ID, notification)
            // Also update the foreground notification to ensure service stays alive
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification)
            }
            Log.d(TAG, "✅ Notification updated: status=$awaitingClipboardPermission, paused=$isPaused")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to update notification: ${e.message}", e)
        }
    }

    private fun observeLatestItem() {
        notificationJob = scope.launch {
            repository.observeHistory(limit = 1).collectLatest { items ->
                latestPreview = items.firstOrNull()?.preview
                updateNotification()
            }
        }
    }

    /**
     * Ensures the database's latest entry matches the current clipboard on startup.
     * If they don't match, updates the database to reflect the current clipboard.
     * This prevents old items from being considered as "latest" when the app restarts.
     */
    private fun ensureDatabaseMatchesCurrentClipboard() {
        scope.launch(Dispatchers.Default) {
            try {
                val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                val parser = ClipboardParser(
                    contentResolver = contentResolver,
                    onFileTooLarge = { filename, size ->
                        showFileTooLargeWarning(filename, size)
                    }
                )
                
                val clip = clipboardManager.primaryClip ?: return@launch
                val currentEvent = parser.parse(clip) ?: return@launch
                
                val latestEntry = repository.getLatestEntry()
                
                // If database has a latest entry, check if it matches current clipboard
                if (latestEntry != null) {
                    val currentItem = ClipboardItem(
                        id = currentEvent.id,
                        type = currentEvent.type,
                        content = currentEvent.content,
                        preview = currentEvent.preview,
                        metadata = currentEvent.metadata.ifEmpty { emptyMap() },
                        deviceId = deviceIdentity.deviceId,
                        deviceName = deviceIdentity.deviceName,
                        createdAt = currentEvent.createdAt,
                        isPinned = false,
                        isEncrypted = false,
                        transportOrigin = null
                    )
                    
                    // If current clipboard doesn't match database latest, update database
                    if (!currentItem.matchesContent(latestEntry)) {
                        Log.d(TAG, "🔄 Current clipboard doesn't match database latest entry - updating database")
                        // Update the timestamp of the matching entry if it exists in history, or create new entry
                        val matchingEntry = repository.findMatchingEntryInHistory(currentItem)
                        if (matchingEntry != null) {
                            // Found in history - move it to top with current time
                            repository.updateTimestamp(matchingEntry.id, Instant.now())
                            Log.d(TAG, "✅ Moved matching history item to top")
                        } else {
                            // Not in history - add as new entry (but don't send it - it's the current clipboard)
                            repository.upsert(currentItem)
                            Log.d(TAG, "✅ Added current clipboard to database as latest entry")
                        }
                    } else {
                        Log.d(TAG, "✅ Database latest entry matches current clipboard")
                    }
                } else {
                    // No latest entry in database - add current clipboard (but don't send it)
                    val currentItem = ClipboardItem(
                        id = currentEvent.id,
                        type = currentEvent.type,
                        content = currentEvent.content,
                        preview = currentEvent.preview,
                        metadata = currentEvent.metadata.ifEmpty { emptyMap() },
                        deviceId = deviceIdentity.deviceId,
                        deviceName = deviceIdentity.deviceName,
                        createdAt = currentEvent.createdAt,
                        isPinned = false,
                        isEncrypted = false,
                        transportOrigin = null
                    )
                    repository.upsert(currentItem)
                    Log.d(TAG, "✅ Added current clipboard to empty database")
                }
            } catch (e: SecurityException) {
                Log.d(TAG, "🔒 Cannot access clipboard to sync with database: ${e.message}")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Error ensuring database matches current clipboard: ${e.message}", e)
            }
        }
    }

    private fun pauseListener() {
        if (isPaused) return
        listener.stop()
        isPaused = true
        updateNotification()
    }

    private fun resumeListener() {
        if (!isPaused) return
        ensureClipboardPermissionAndStartListener()
        isPaused = false
        updateNotification()
    }

    private fun pendingIntentForAction(action: String): PendingIntent {
        // For accessibility settings, open directly instead of going through service
        // This ensures it works even when service is already running
        val intent = when (action) {
            ACTION_OPEN_ACCESSIBILITY_SETTINGS -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                } else {
                    Intent(Settings.ACTION_SETTINGS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                }
            }
            ACTION_OPEN_CLIPBOARD_SETTINGS -> {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = android.net.Uri.fromParts("package", packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
            else -> {
                // For other actions, use service intent
                Intent(this, ClipboardSyncService::class.java).setAction(action)
            }
        }
        
        return if (action == ACTION_OPEN_ACCESSIBILITY_SETTINGS || action == ACTION_OPEN_CLIPBOARD_SETTINGS) {
            // Use getActivity for settings intents
            PendingIntent.getActivity(
                this,
                action.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            // Use getService for service actions
            PendingIntent.getService(
                this,
                action.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
    }

    private fun registerScreenStateReceiver() {
        screenStateReceiver = ScreenStateReceiver(
            onScreenOff = { handleScreenOff() },
            onScreenOn = { handleScreenOn() }
        )
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }
        registerReceiver(screenStateReceiver, filter)
        Log.d(TAG, "Screen state receiver registered for battery optimization")
    }

    private fun unregisterScreenStateReceiver() {
        runCatching {
            unregisterReceiver(screenStateReceiver)
            Log.d(TAG, "Screen state receiver unregistered")
        }
    }
    
    private fun registerNetworkChangeCallback() {
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        networkCallback = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) {
                super.onAvailable(network)
                android.util.Log.d(TAG, "🌐 Network became available - restarting LAN services and reconnecting cloud")
                // Restart LAN services to update IP address in Bonjour/NSD and WebSocket server
                transportManager.restartForNetworkChange()
                // Reconnect cloud WebSocket to use new IP address
                scope.launch {
                    relayWebSocketClient.reconnect()
                }
                connectionStatusProber.probeNow()
            }

            override fun onLost(network: android.net.Network) {
                super.onLost(network)
                android.util.Log.d(TAG, "🌐 Network lost - triggering immediate probe")
                connectionStatusProber.probeNow()
            }

            override fun onCapabilitiesChanged(
                network: android.net.Network,
                networkCapabilities: android.net.NetworkCapabilities
            ) {
                super.onCapabilitiesChanged(network, networkCapabilities)
                android.util.Log.d(TAG, "🌐 Network capabilities changed - restarting LAN services and reconnecting cloud")
                // Restart LAN services when network capabilities change (e.g., IP address change)
                transportManager.restartForNetworkChange()
                // Reconnect cloud WebSocket to use new IP address
                scope.launch {
                    relayWebSocketClient.reconnect()
                }
                connectionStatusProber.probeNow()
            }
        }
        val request = android.net.NetworkRequest.Builder()
            .addCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivityManager.registerNetworkCallback(request, networkCallback!!)
        android.util.Log.d(TAG, "Network connectivity callback registered")
    }
    
    private fun unregisterNetworkChangeCallback() {
        networkCallback?.let { callback ->
            runCatching {
                connectivityManager.unregisterNetworkCallback(callback)
                android.util.Log.d(TAG, "Network connectivity callback unregistered")
            }
            networkCallback = null
        }
    }

    private fun handleScreenOff() {
        if (isScreenOff) return
        isScreenOff = true
        Log.d(TAG, "Screen OFF - idling WebSocket connections to save battery")
        // Transport Manager will let idle timeout trigger faster
        // WebSocket watchdog will close idle connections
        transportManager.stopConnectionSupervisor()
    }

    private fun handleScreenOn() {
        if (!isScreenOff) return
        isScreenOff = false
        Log.d(TAG, "Screen ON - resuming WebSocket connections")
        // Restart transport will reconnect when needed
        transportManager.start(buildLanRegistrationConfig())
    }
    
    private fun checkAppForegroundState() {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return
        val isForeground = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // Modern approach: check running app processes
                val runningProcesses = activityManager.runningAppProcesses
                val currentProcess = runningProcesses?.find { it.pid == android.os.Process.myPid() }
                currentProcess?.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
            } else {
                // Fallback for older Android versions
                @Suppress("DEPRECATION")
                val runningTasks = activityManager.getRunningTasks(1)
                runningTasks.isNotEmpty() && runningTasks[0].topActivity?.packageName == packageName
            }
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Failed to check foreground state: ${e.message}")
            false
        }
        
        if (isForeground != isAppInForeground) {
            isAppInForeground = isForeground
            val status = if (isForeground) "FOREGROUND" else "BACKGROUND"
            Log.d(TAG, "📱 App state: $status")
            if (!isForeground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !isAccessibilityServiceEnabled) {
                Log.w(TAG, "⚠️ Clipboard access BLOCKED in background. Enable accessibility service for background access.")
            }
            updateNotification()
        }
    }
    
    private fun checkAccessibilityServiceStatus() {
        val accessibilityManager = getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager ?: return
        val enabledServices = accessibilityManager.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
        val serviceClassName = ClipboardAccessibilityService::class.java.name
        val serviceName = ComponentName(packageName, serviceClassName)
        
        // Check if our accessibility service is enabled
        val isEnabled = enabledServices.any { serviceInfo ->
            val componentName = ComponentName(
                serviceInfo.resolveInfo.serviceInfo.packageName,
                serviceInfo.resolveInfo.serviceInfo.name
            )
            componentName == serviceName || serviceInfo.resolveInfo.serviceInfo.name == serviceClassName
        }
        
        if (isEnabled != isAccessibilityServiceEnabled) {
            isAccessibilityServiceEnabled = isEnabled
            val status = if (isEnabled) "ENABLED" else "DISABLED"
            Log.i(TAG, "♿ Accessibility service: $status (allows background clipboard access on Android 10+)")
            if (isEnabled) {
                Log.i(TAG, "✅ Background clipboard access is now available via accessibility service!")
                // Stop ClipboardListener to prevent duplicates - accessibility service will handle clipboard monitoring
                Log.i(TAG, "🛑 Stopping ClipboardListener to prevent duplicates (accessibility service will handle monitoring)")
                listener.stop()
            } else {
                // Accessibility service disabled - start ClipboardListener if not already running
                if (!listener.isListening) {
                    Log.i(TAG, "🔄 Accessibility service disabled - starting ClipboardListener")
                    ensureClipboardPermissionAndStartListener()
                }
            }
            updateNotification()
        }
    }

    private fun ensureClipboardPermissionAndStartListener() {
        // Don't start ClipboardListener if accessibility service is enabled (prevents duplicates)
        if (isAccessibilityServiceEnabled) {
            Log.i(TAG, "⏭️ Skipping ClipboardListener start - accessibility service is enabled and will handle clipboard monitoring")
            return
        }
        
        clipboardPermissionJob?.cancel()
        clipboardPermissionJob = scope.launch {
            Log.i(TAG, "🔍 Starting clipboard permission check loop...")
            while (isActive) {
                // Check again if accessibility service was enabled while waiting
                if (isAccessibilityServiceEnabled) {
                    Log.i(TAG, "⏭️ Accessibility service enabled during permission check - stopping ClipboardListener setup")
                    return@launch
                }
                
                val allowed = clipboardAccessChecker.canReadClipboard()
                awaitingClipboardPermission = !allowed
                Log.d(TAG, "📋 Clipboard permission status: allowed=$allowed, awaiting=$awaitingClipboardPermission")
                updateNotification()
                if (allowed) {
                    Log.i(TAG, "✅ Clipboard permission granted! Starting ClipboardListener...")
                    listener.start()
                    Log.i(TAG, "✅ ClipboardListener started successfully")
                    return@launch
                } else {
                    Log.w(TAG, "⚠️ Clipboard access denied. Waiting for user consent… (will retry in 5s)")
                    delay(5_000)
                }
            }
            Log.w(TAG, "⚠️ Clipboard permission check loop ended (scope cancelled)")
        }
    }

    private fun openClipboardSettings() {
        // Try to open AppOps settings directly for clipboard permission
        // This is more direct than opening general app settings
        val intent = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Android 10+: Try to open AppOps settings for clipboard
                Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = android.net.Uri.fromParts("package", packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    putExtra("android.provider.extra.APP_PACKAGE", packageName)
                }
            } else {
                Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = android.net.Uri.fromParts("package", packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to create settings intent: ${e.message}")
            Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.fromParts("package", packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        
        Log.d(TAG, "📱 Opening clipboard permission settings...")
        runCatching { 
            startActivity(intent)
            Log.d(TAG, "✅ Settings activity started")
        }.onFailure { e ->
            Log.e(TAG, "❌ Failed to open settings: ${e.message}", e)
        }
    }
    
    private fun openAccessibilitySettings() {
        val intent = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            } else {
                // Fallback for older Android versions
                Intent(Settings.ACTION_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to create accessibility settings intent: ${e.message}")
            Intent(Settings.ACTION_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        
        Log.i(TAG, "♿ Opening accessibility settings...")
        try {
            startActivity(intent)
            Log.i(TAG, "✅ Accessibility settings activity started")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to open accessibility settings: ${e.message}", e)
            // Fallback: try opening general settings
            try {
                val fallbackIntent = Intent(Settings.ACTION_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(fallbackIntent)
                Log.i(TAG, "✅ Opened general settings as fallback")
            } catch (e2: Exception) {
                Log.e(TAG, "❌ Failed to open fallback settings: ${e2.message}", e2)
            }
        }
    }

    private fun buildLanRegistrationConfig(): LanRegistrationConfig {
        val version = runCatching {
            val packageInfo = packageManager.getPackageInfo(packageName, 0)
            packageInfo.versionName ?: DEFAULT_VERSION
        }.getOrDefault(DEFAULT_VERSION)

        // Load or generate persistent pairing keys for LAN auto-discovery
        val (publicKeyBase64, signingPublicKeyBase64) = loadOrCreatePairingKeys()

        // Derive fingerprint from the LAN agreement public key (stable across restarts)
        val fingerprint = publicKeyBase64
            ?.let { Base64.decode(it, Base64.DEFAULT) }
            ?.let { sha256Hex(it) }
            ?: TransportManager.DEFAULT_FINGERPRINT

        return LanRegistrationConfig(
            serviceName = deviceIdentity.deviceId,
            port = TransportManager.DEFAULT_PORT,
            fingerprint = fingerprint,
            version = version,
            protocols = TransportManager.DEFAULT_PROTOCOLS,
            deviceId = deviceIdentity.deviceId,
            publicKey = publicKeyBase64,
            signingPublicKey = signingPublicKeyBase64
        )
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val sb = StringBuilder(digest.size * 2)
        for (b in digest) {
            sb.append(String.format("%02x", b))
        }
        return sb.toString()
    }
    
    private fun loadOrCreatePairingKeys(): Pair<String?, String?> {
        return try {
            val prefs = getSharedPreferences("hypo_pairing_keys", Context.MODE_PRIVATE)
            
            // Load or create Curve25519 key agreement key
            val agreementKeyBase64 = prefs.getString("lan_agreement_public_key", null)
            val agreementPublicKey = if (agreementKeyBase64 != null) {
                agreementKeyBase64
            } else {
                // Generate new key pair
                val privateKey = X25519.generatePrivateKey()
                val publicKey = X25519.publicFromPrivate(privateKey)
                val publicKeyBase64 = android.util.Base64.encodeToString(publicKey, android.util.Base64.NO_WRAP)
                // Store private key (for later use during pairing)
                val privateKeyBase64 = android.util.Base64.encodeToString(privateKey, android.util.Base64.NO_WRAP)
                prefs.edit()
                    .putString("lan_agreement_public_key", publicKeyBase64)
                    .putString("lan_agreement_private_key", privateKeyBase64)
                    .apply()
                Log.d(TAG, "🔑 Generated new LAN pairing agreement key")
                publicKeyBase64
            }
            
            // Load or create Ed25519 signing key
            val signingKeyBase64 = prefs.getString("lan_signing_public_key", null)
            val signingPublicKey = if (signingKeyBase64 != null) {
                signingKeyBase64
            } else {
                // Generate new signing key pair using Ed25519Sign.KeyPair
                val keyPair = Ed25519Sign.KeyPair.newKeyPair()
                val publicKey = keyPair.publicKey
                val privateKey = keyPair.privateKey
                val publicKeyBase64 = android.util.Base64.encodeToString(publicKey, android.util.Base64.NO_WRAP)
                // Store private key (for signing QR payloads)
                val privateKeyBase64 = android.util.Base64.encodeToString(privateKey, android.util.Base64.NO_WRAP)
                prefs.edit()
                    .putString("lan_signing_public_key", publicKeyBase64)
                    .putString("lan_signing_private_key", privateKeyBase64)
                    .apply()
                Log.d(TAG, "🔑 Generated new LAN pairing signing key")
                publicKeyBase64
            }
            
            Pair(agreementPublicKey, signingPublicKey)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load/create pairing keys: ${e.message}", e)
            Pair(null, null)
        }
    }

    private fun showFileTooLargeWarning(filename: String, size: Long) {
        val sizeMB = size / (1024.0 * 1024.0)
        val maxMB = 10.0
        val message = getString(R.string.file_too_large_warning, filename, String.format("%.1f", sizeMB), String.format("%.0f", maxMB))
        
        val contentIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        
        val notification = NotificationCompat.Builder(this, WARNING_CHANNEL_ID)
            .setContentTitle(getString(R.string.file_too_large_title))
            .setContentText(message)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(contentPendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ERROR)
            .setStyle(NotificationCompat.BigTextStyle().bigText(message))
            .build()
        
        notificationManager.notify(WARNING_NOTIFICATION_ID, notification)
        Log.w(TAG, "⚠️ File too large: $filename (${size / (1024 * 1024)}MB)")
    }

    companion object {
        private const val TAG = "ClipboardSyncService"
        private const val CHANNEL_ID = "clipboard-sync"
        private const val WARNING_CHANNEL_ID = "clipboard-warnings"
        private const val NOTIFICATION_ID = 42
        private const val WARNING_NOTIFICATION_ID = 43
        private const val DEFAULT_VERSION = "1.0.0"
        private const val ACTION_PAUSE = "com.hypo.clipboard.action.PAUSE"
        private const val ACTION_RESUME = "com.hypo.clipboard.action.RESUME"
        private const val ACTION_OPEN_CLIPBOARD_SETTINGS = "com.hypo.clipboard.action.OPEN_CLIPBOARD_SETTINGS"
        private const val ACTION_OPEN_ACCESSIBILITY_SETTINGS = "com.hypo.clipboard.action.OPEN_ACCESSIBILITY_SETTINGS"
        private const val ACTION_STOP = "com.hypo.clipboard.action.STOP"
    }
}
