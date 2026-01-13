package com.hypo.clipboard.service

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.hypo.clipboard.MainActivity
import com.hypo.clipboard.R
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.sync.ClipboardListener
import com.hypo.clipboard.sync.ClipboardParser
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.SyncCoordinator
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.LanRegistrationConfig
import com.hypo.clipboard.util.MiuiAdapter
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
    @Inject lateinit var lanWebSocketClient: com.hypo.clipboard.transport.ws.WebSocketTransportClient
    @Inject lateinit var relayWebSocketClient: com.hypo.clipboard.transport.ws.RelayWebSocketClient
    @Inject lateinit var clipboardAccessChecker: com.hypo.clipboard.sync.ClipboardAccessChecker
    @Inject lateinit var connectionStatusProber: com.hypo.clipboard.transport.ConnectionStatusProber
    @Inject lateinit var pairingHandshakeManager: com.hypo.clipboard.pairing.PairingHandshakeManager
    @Inject lateinit var storageManager: com.hypo.clipboard.data.local.StorageManager
    @Inject lateinit var accessibilityServiceChecker: com.hypo.clipboard.util.AccessibilityServiceChecker

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
    private lateinit var screenStateReceiver: ScreenStateReceiver
    private var networkCallback: android.net.ConnectivityManager.NetworkCallback? = null
    private lateinit var connectivityManager: android.net.ConnectivityManager

    override fun onCreate() {
        super.onCreate()
        
        // Log MIUI/HyperOS device information for debugging
        MiuiAdapter.logDeviceInfo()
        
        notificationManager = NotificationManagerCompat.from(this)
        createNotificationChannel()
        
        // Start foreground service immediately to keep app alive
        val notification = buildNotification()
        Log.d(TAG, "🚀 Starting foreground service with notification ID=$NOTIFICATION_ID, channel=$CHANNEL_ID")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            Log.d(TAG, "✅ Foreground service started successfully")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to start foreground service: ${e.message}", e)
        }

        val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        val parser = ClipboardParser(
            contentResolver = contentResolver,
            storageManager = storageManager,
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
            try {
                // Load persistent LAN pairing private key
                val prefs = getSharedPreferences("hypo_pairing_keys", Context.MODE_PRIVATE)
                val privateKeyBase64 = prefs.getString("lan_agreement_private_key", null)
                if (privateKeyBase64 == null) {
                    Log.e(TAG, "❌ Pairing: No LAN private key found (available keys: ${prefs.all.keys})")
                    return@setPairingChallengeHandler null
                }
                
                val privateKey = android.util.Base64.decode(privateKeyBase64, android.util.Base64.NO_WRAP)
                val ackJson = pairingHandshakeManager.handleChallenge(challengeJson, privateKey)
                
                if (ackJson != null) {
                    Log.d(TAG, "✅ Pairing: Challenge handled → ACK generated (${ackJson.length} chars)")
                } else {
                    Log.e(TAG, "❌ Pairing: Failed to generate ACK from challenge")
                }
                ackJson
            } catch (e: Exception) {
                Log.e(TAG, "❌ Pairing: Error handling challenge - ${e.javaClass.simpleName}: ${e.message}", e)
                null
            }
        }
        
        lanWebSocketClient.setIncomingClipboardHandler { envelope, origin ->
            incomingClipboardHandler.handle(envelope, origin)
        }
        relayWebSocketClient.setIncomingClipboardHandler { envelope, origin ->
            incomingClipboardHandler.handle(envelope, origin)
        }
        
        // Set up error handlers for sync failures
        val errorHandler: (String, String) -> Unit = { deviceId, _ ->
            scope.launch(Dispatchers.Main) {
                val deviceName = transportManager.getDeviceName(deviceId) ?: deviceId.take(20)
                val toastMessage = "Failed to sync to $deviceName: incorrect device_id ($deviceId)"
                android.util.Log.e(TAG, "❌ $toastMessage")
                android.widget.Toast.makeText(
                    this@ClipboardSyncService,
                    toastMessage,
                    android.widget.Toast.LENGTH_LONG
                ).show()
            }
        }
        lanWebSocketClient.setSyncErrorHandler(errorHandler)
        relayWebSocketClient.setSyncErrorHandler(errorHandler)
        // Set handler for LAN WebSocket server (incoming connections from other devices)
        transportManager.setIncomingClipboardHandler { envelope, origin ->
            incomingClipboardHandler.handle(envelope, origin)
        }
        
        // Set handler for LAN peer connections (created by LanPeerConnectionManager)
        // Get LanPeerConnectionManager from TransportManager's internal reference
        val lanPeerConnectionManager = transportManager.getLanPeerConnectionManager()
        if (lanPeerConnectionManager != null) {
            lanPeerConnectionManager.setIncomingClipboardHandler { envelope, origin ->
                incomingClipboardHandler.handle(envelope, origin)
            }
            Log.d(TAG, "✅ Set incoming clipboard handler for LAN peer connections")
        } else {
            Log.w(TAG, "⚠️ LanPeerConnectionManager not available, peer connections won't receive messages")
        }
        
        // Start receiving connections for both LAN and cloud
        // NOTE: relayWebSocketClient creates its own WebSocketTransportClient instance,
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
        
        // Monitor app foreground state
        scope.launch {
            while (isActive) {
                val wasForeground = isAppInForeground
                checkAppForegroundState()
                // When app becomes active, check clipboard for new content
                if (!wasForeground && isAppInForeground) {
                    Log.d(TAG, "📱 App became active - checking clipboard for new content")
                    connectionStatusProber.probeNow()
                    // Trigger clipboard check to catch any changes that occurred while app was in background
                    if (::listener.isInitialized) {
                        listener.forceProcessCurrentClipboard()
                    }
                }
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
            ACTION_FORCE_PROCESS_CLIPBOARD -> {
                Log.d(TAG, "🔄 Force processing clipboard from ProcessTextActivity")
                // Get text from intent if available (avoids timing issues with clipboard access)
                val textFromIntent = intent.getStringExtra("text")
                if (textFromIntent != null) {
                    Log.d(TAG, "📝 Processing text from intent (${textFromIntent.length} chars)")
                    // Create a ClipboardEvent directly from the text
                    scope.launch {
                        try {
                            val bytes = textFromIntent.encodeToByteArray()
                            val digest = java.security.MessageDigest.getInstance("SHA-256")
                            val hashBytes = digest.digest(bytes)
                            val hash = hashBytes.joinToString("") { "%02x".format(it) }
                            
                            val event = com.hypo.clipboard.sync.ClipboardEvent(
                                id = java.util.UUID.randomUUID().toString(),
                                type = if (android.util.Patterns.WEB_URL.matcher(textFromIntent).matches()) {
                                    com.hypo.clipboard.domain.model.ClipboardType.LINK
                                } else {
                                    com.hypo.clipboard.domain.model.ClipboardType.TEXT
                                },
                                content = textFromIntent,
                                preview = textFromIntent.take(100),
                                metadata = mapOf(
                                    "size" to bytes.size.toString(),
                                    "hash" to hash,
                                    "encoding" to "UTF-8"
                                ),
                                createdAt = java.time.Instant.now()
                            )
                            syncCoordinator.onClipboardEvent(event)
                            Log.d(TAG, "✅ Processed text from ProcessTextActivity and synced to peers")
                        } catch (e: Exception) {
                            Log.e(TAG, "❌ Error processing text from intent: ${e.message}. Attempting fallback to clipboard.", e)
                            // Fallback: try to process from clipboard (may have timing issues)
                            listener.forceProcessCurrentClipboard()
                        }
                    }
                } else {
                    // No URI in intent - process from clipboard directly
                    // Note: This may have timing issues if clipboard changes between intent and processing
                    Log.d(TAG, "⚠️ No URI in intent, processing from clipboard (may have timing issues)")
                    if (!listener.isListening) {
                        Log.d(TAG, "⚠️ Listener not started, attempting to start it first...")
                        scope.launch {
                            val allowed = clipboardAccessChecker.canReadClipboard()
                            if (allowed) {
                                listener.start()
                                Log.d(TAG, "✅ Listener started, now processing clipboard")
                                listener.forceProcessCurrentClipboard()
                            } else {
                                Log.w(TAG, "⚠️ Cannot process: clipboard permission not granted")
                            }
                        }
                    } else {
                        listener.forceProcessCurrentClipboard()
                    }
                }
            }
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }

        // Ensure LAN advertising is running (START_STICKY restarts may drop NSD registration)
        ensureLanAdvertising()
        // Ensure clipboard listener is running (restarts may have stopped it)
        ensureClipboardListenerIsRunning()
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
            
            // Check if notifications are enabled for the app
            val areNotificationsEnabled = notificationManager.areNotificationsEnabled()
            Log.d(TAG, "📱 App notifications enabled: $areNotificationsEnabled")
            
            // Main sync channel
            // Use IMPORTANCE_DEFAULT to ensure notification is visible in notification list
            // This allows users to see the latest clipboard item persistently
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.service_notification_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = getString(R.string.service_notification_channel_description)
                setShowBadge(false)  // Don't show badge to avoid clutter
                enableLights(false)  // Don't flash LED
                enableVibration(false)  // Don't vibrate
                setSound(null, null)  // No sound for persistent notification
            }
            manager.createNotificationChannel(channel)
            
            // Verify channel was created with correct importance
            val createdChannel = manager.getNotificationChannel(CHANNEL_ID)
            if (createdChannel != null) {
                val importance = createdChannel.importance
                val importanceText = when (importance) {
                    NotificationManager.IMPORTANCE_NONE -> "NONE (blocked)"
                    NotificationManager.IMPORTANCE_MIN -> "MIN (hidden)"
                    NotificationManager.IMPORTANCE_LOW -> "LOW (minimized)"
                    NotificationManager.IMPORTANCE_DEFAULT -> "DEFAULT (visible)"
                    NotificationManager.IMPORTANCE_HIGH -> "HIGH (visible + sound)"
                    else -> "UNKNOWN ($importance)"
                }
                Log.d(TAG, "✅ Notification channel created: id=$CHANNEL_ID, importance=$importanceText")
                
                if (importance == NotificationManager.IMPORTANCE_NONE) {
                    Log.e(TAG, "❌ CRITICAL: Notification channel is blocked (IMPORTANCE_NONE) - notification will NOT be shown!")
                    Log.e(TAG, "   User must enable notifications in: Settings → Apps → Hypo → Notifications → Clipboard Sync")
                } else if (importance != NotificationManager.IMPORTANCE_DEFAULT) {
                    Log.w(TAG, "⚠️ Notification channel importance is $importanceText (expected DEFAULT)")
                }
            } else {
                Log.e(TAG, "❌ CRITICAL: Failed to create notification channel: $CHANNEL_ID")
            }
            
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
        val previewText = when {
            awaitingClipboardPermission -> getString(R.string.service_notification_permission_body)
            // Always show latest clipboard preview if available (from database)
            // Only show background warning if no preview is available
            latestPreview != null -> latestPreview!!
            !isAppInForeground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> "App must be in foreground for clipboard access on Android 10+"
            else -> getString(R.string.service_notification_text)
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
            // Use PRIORITY_DEFAULT to match channel importance (PRIORITY_LOW may hide notification)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(previewText)
            )

        // Show action buttons based on state
        if (awaitingClipboardPermission) {
            builder.addAction(
                R.drawable.ic_notification,
                getString(R.string.action_grant_clipboard_access),
                pendingIntentForAction(ACTION_OPEN_CLIPBOARD_SETTINGS)
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
            
            // Verify notification is actually shown (for debugging)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val isNotificationEnabled = notificationManager.areNotificationsEnabled()
                val channel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    notificationManager.getNotificationChannel(CHANNEL_ID)
                } else {
                    null
                }
                val channelBlocked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && channel != null) {
                    channel.importance == NotificationManager.IMPORTANCE_NONE
                } else {
                    false
                }
                val channelImportance = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && channel != null) {
                    channel.importance
                } else {
                    -1
                }
                
                Log.d(TAG, "✅ Notification updated: status=$awaitingClipboardPermission, paused=$isPaused, " +
                        "notificationsEnabled=$isNotificationEnabled, channelBlocked=$channelBlocked, " +
                        "channelImportance=$channelImportance, preview=${latestPreview?.take(30) ?: "none"}")
                
                if (!isNotificationEnabled) {
                    Log.w(TAG, "⚠️ Notifications are disabled for this app - notification will not be shown")
                }
                if (channelBlocked) {
                    Log.w(TAG, "⚠️ Notification channel is blocked (IMPORTANCE_NONE) - notification will not be shown")
                }
            } else {
                Log.d(TAG, "✅ Notification updated: status=$awaitingClipboardPermission, paused=$isPaused, preview=${latestPreview?.take(30) ?: "none"}")
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to update notification: ${e.message}", e)
        }
    }

    private fun observeLatestItem() {
        notificationJob?.cancel() // Cancel previous job if exists
        notificationJob = scope.launch {
            Log.d(TAG, "👀 Starting to observe latest clipboard item for notification updates")
            try {
                repository.observeHistory(limit = 1).collectLatest { items ->
                    val preview = items.firstOrNull()?.preview
                    if (preview != latestPreview) {
                        Log.d(TAG, "📋 Latest item changed: preview=${preview?.take(30) ?: "none"}")
                        latestPreview = preview
                        updateNotification()
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error observing latest item: ${e.message}", e)
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
                    storageManager = storageManager,
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
        val intent = when (action) {
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
        
        return if (action == ACTION_OPEN_CLIPBOARD_SETTINGS) {
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
        
        // Get the current active network BEFORE registering callback
        // This prevents the initial onAvailable() calls from triggering false network changes
        val currentNetwork = connectivityManager.activeNetwork
        val currentNetworkId = currentNetwork?.hashCode()
        
        var lastNetworkChangeTime = 0L
        var lastActiveNetworkId: Int? = currentNetworkId  // Initialize with current network
        val networkChangeDebounceMs = 1000L // 1 second debounce
        
        android.util.Log.d(TAG, "🌐 Registering default network callback - current network ID: $currentNetworkId")
        
        networkCallback = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) {
                super.onAvailable(network)
                val now = System.currentTimeMillis()
                val networkId = network.hashCode()
                
                android.util.Log.d(TAG, "🌐 Default network available (ID: $networkId) (current active: $currentNetworkId, lastActive: $lastActiveNetworkId)")
                
                // If this is the initial callback for the current network, ignore it
                // We only want to react to subsequent changes
                if (currentNetworkId != null && networkId == currentNetworkId && lastActiveNetworkId == currentNetworkId) {
                    android.util.Log.d(TAG, "🌐 Initial callback for current network ($networkId) - ignoring")
                    return
                }
                
                // If the network ID hasn't changed, ignore (e.g. signal strength change or re-connect to same network)
                // However, if lastActiveNetworkId is null (from onLost), we SHOULD process this
                if (lastActiveNetworkId == networkId) {
                    android.util.Log.d(TAG, "🌐 Network available but same network active ($networkId) - ignoring")
                    return
                }
                
                if (now - lastNetworkChangeTime < networkChangeDebounceMs) {
                    android.util.Log.d(TAG, "🌐 Network change debounced (${now - lastNetworkChangeTime}ms since last)")
                    return
                }
                lastNetworkChangeTime = now
                lastActiveNetworkId = networkId
                android.util.Log.d(TAG, "🌐 New default network became available (ID: $networkId) - restarting LAN services and reconnecting cloud")
                
                // Restart LAN services to update IP address in Bonjour/NSD and WebSocket server
                transportManager.restartForNetworkChange()
                
                // Reconnect cloud WebSocket to use new IP address (debounced to avoid cancelling in-progress connections)
                scope.launch {
                    kotlinx.coroutines.delay(500) // Wait 500ms to let any in-progress connection cleanup
                    relayWebSocketClient.reconnect()
                }
                connectionStatusProber.probeNow()
            }

            override fun onLost(network: android.net.Network) {
                super.onLost(network)
                val networkId = network.hashCode()
                if (lastActiveNetworkId == networkId) {
                    lastActiveNetworkId = null
                    android.util.Log.d(TAG, "🌐 Default network lost (ID: $networkId) - waiting for new default network")
                } else {
                    android.util.Log.d(TAG, "🌐 Network lost but not the active default (ID: $networkId) - ignoring")
                }
            }

            override fun onCapabilitiesChanged(
                network: android.net.Network,
                networkCapabilities: android.net.NetworkCapabilities
            ) {
                super.onCapabilitiesChanged(network, networkCapabilities)
                // Ignore capability changes - only care about default network switches
            }
        }
        
        // Use registerDefaultNetworkCallback to only track changes to the system default network
        // This is robust against multi-network scenarios (WiFi + Cellular) and only fires
        // when the active primary network actually changes.
        // Min SDK is 26, so this API (added in API 24) is safe to use.
        connectivityManager.registerDefaultNetworkCallback(networkCallback!!)
        android.util.Log.d(TAG, "Default network connectivity callback registered")
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
        Log.d(TAG, "Screen OFF - closing LAN connections to save battery")
        scope.launch {
            // Close all LAN connections to save battery
            transportManager.closeAllLanConnections()
            // Stop connection supervisor (already stops cloud connection supervision)
            transportManager.stopConnectionSupervisor()
        }
    }

    private fun handleScreenOn() {
        if (!isScreenOff) return
        isScreenOff = false
        Log.d(TAG, "Screen ON - reconnecting LAN connections")
        scope.launch {
            // Reconnect all LAN connections
            transportManager.reconnectAllLanConnections()
            // Restart cloud connection to ensure it reconnects after screen was off
            // The connection loop should handle reconnection automatically, but calling startReceiving()
            // ensures the connection job is active if it was stopped
            relayWebSocketClient.startReceiving()
        }
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
            if (!isForeground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                Log.w(TAG, "⚠️ Clipboard access BLOCKED in background on Android 10+. App must be in foreground.")
            }
            updateNotification()
        }
    }

    private fun ensureClipboardPermissionAndStartListener() {
        clipboardPermissionJob?.cancel()
        clipboardPermissionJob = scope.launch {
            try {
                while (isActive) {
                    // Check if AccessibilityService is enabled - if so, it handles clipboard monitoring
                    // Don't start ClipboardListener to avoid duplicate processing
                    val accessibilityEnabled = accessibilityServiceChecker.isAccessibilityServiceEnabled()
                    if (accessibilityEnabled) {
                        // AccessibilityService handles clipboard monitoring, don't start ClipboardListener
                        awaitingClipboardPermission = false
                        updateNotification()
                        return@launch
                    }
                    
                    val allowed = clipboardAccessChecker.canReadClipboard()
                    awaitingClipboardPermission = !allowed
                    updateNotification()
                    if (allowed) {
                        listener.start()
                        return@launch
                    } else {
                        delay(5_000)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Exception in clipboard permission check coroutine: ${e.message}", e)
            }
        }
    }

    private fun ensureClipboardListenerIsRunning() {
        // Check if listener is already active
        if (listener.isListening) {
            Log.d(TAG, "✅ Clipboard listener is already running")
            return
        }
        
        Log.w(TAG, "⚠️ Clipboard listener is NOT running, attempting to restart...")
        // Restart the permission check and listener startup process
        ensureClipboardPermissionAndStartListener()
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
            serviceName = buildLanServiceName(),
            port = TransportManager.DEFAULT_PORT,
            fingerprint = fingerprint,
            version = version,
            protocols = TransportManager.DEFAULT_PROTOCOLS,
            deviceId = deviceIdentity.deviceId,
            publicKey = publicKeyBase64,
            signingPublicKey = signingPublicKeyBase64
        )
    }

    private fun buildLanServiceName(): String {
        val rawName = deviceIdentity.deviceName.trim()
        val base = if (rawName.isNotEmpty()) rawName else deviceIdentity.deviceId
        val sanitized = base.replace(Regex("[\\u0000-\\u001F\\u007F]"), " ").trim()
        val maxBytes = 63
        val bytes = sanitized.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) {
            return sanitized
        }
        val suffix = "-${deviceIdentity.deviceId.take(4)}"
        val suffixBytes = suffix.toByteArray(Charsets.UTF_8)
        val targetBytes = maxBytes - suffixBytes.size
        if (targetBytes <= 0) {
            return deviceIdentity.deviceId
        }
        // Truncate by UTF-8 byte length to avoid invalid sequences.
        var byteCount = 0
        val sb = StringBuilder()
        for (ch in sanitized) {
            val chBytes = ch.toString().toByteArray(Charsets.UTF_8)
            if (byteCount + chBytes.size > targetBytes) break
            sb.append(ch)
            byteCount += chBytes.size
        }
        return sb.toString().trim().ifEmpty { deviceIdentity.deviceId } + suffix
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
        // Changed channel ID to force recreation with IMPORTANCE_DEFAULT
        // Old channel with IMPORTANCE_LOW cannot be changed programmatically on Android 8.0+
        private const val CHANNEL_ID = "clipboard-sync-v2"
        private const val WARNING_CHANNEL_ID = "clipboard-warnings"
        private const val NOTIFICATION_ID = 42
        private const val WARNING_NOTIFICATION_ID = 43
        private const val DEFAULT_VERSION = "1.0.0"
        private const val ACTION_PAUSE = "com.hypo.clipboard.action.PAUSE"
        private const val ACTION_RESUME = "com.hypo.clipboard.action.RESUME"
        private const val ACTION_OPEN_CLIPBOARD_SETTINGS = "com.hypo.clipboard.action.OPEN_CLIPBOARD_SETTINGS"
        private const val ACTION_STOP = "com.hypo.clipboard.action.STOP"
        const val ACTION_FORCE_PROCESS_CLIPBOARD = "com.hypo.clipboard.action.FORCE_PROCESS_CLIPBOARD"
    }
}
