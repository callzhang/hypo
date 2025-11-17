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
import com.hypo.clipboard.service.ClipboardAccessibilityService
import com.hypo.clipboard.sync.ClipboardListener
import com.hypo.clipboard.sync.ClipboardParser
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.SyncCoordinator
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.LanRegistrationConfig
import dagger.hilt.android.AndroidEntryPoint
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
    @Inject lateinit var clipboardAccessChecker: com.hypo.clipboard.sync.ClipboardAccessChecker

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

    override fun onCreate() {
        super.onCreate()
        android.util.Log.i("ClipboardSyncService", "🚀🚀🚀 SERVICE onCreate() CALLED! Starting initialization...")
        notificationManager = NotificationManagerCompat.from(this)
        createNotificationChannel()
        
        // Start foreground service immediately to keep app alive
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        android.util.Log.i("ClipboardSyncService", "✅ Service started foreground with notification (keeps app alive for clipboard access)")

        val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        val parser = ClipboardParser(contentResolver)
        val clipboardCallback: suspend (com.hypo.clipboard.sync.ClipboardEvent) -> Unit = { event ->
            syncCoordinator.onClipboardEvent(event)
        }
        
        listener = ClipboardListener(
            clipboardManager = clipboardManager,
            parser = parser,
            onClipboardChanged = clipboardCallback,
            scope = scope
        )

        android.util.Log.i("ClipboardSyncService", "🎯 Starting sync coordinator...")
        syncCoordinator.start(scope)
        android.util.Log.i("ClipboardSyncService", "🌐 Starting transport manager...")
        transportManager.start(buildLanRegistrationConfig())
        android.util.Log.i("ClipboardSyncService", "📥 Setting up incoming clipboard handler...")
        lanWebSocketClient.setIncomingClipboardHandler { envelope ->
            incomingClipboardHandler.handle(envelope)
        }
        android.util.Log.i("ClipboardSyncService", "📋 Starting clipboard listener...")
        ensureClipboardPermissionAndStartListener()
        android.util.Log.i("ClipboardSyncService", "👀 Observing latest item...")
        observeLatestItem()
        android.util.Log.i("ClipboardSyncService", "📱 Registering screen state receiver...")
        registerScreenStateReceiver()
        
        // Monitor app foreground state and accessibility service status
        scope.launch {
            while (isActive) {
                checkAppForegroundState()
                checkAccessibilityServiceStatus()
                delay(2_000) // Check every 2 seconds
            }
        }
        
        android.util.Log.i("ClipboardSyncService", "✅✅✅ SERVICE FULLY INITIALIZED AND READY!")
    }

    override fun onDestroy() {
        notificationJob?.cancel()
        unregisterScreenStateReceiver()
        listener.stop()
        syncCoordinator.stop()
        clipboardPermissionJob?.cancel()
        transportManager.stop()
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
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
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
            Log.i(TAG, "📱 App state: $status")
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
            }
            updateNotification()
        }
    }

    private fun ensureClipboardPermissionAndStartListener() {
        clipboardPermissionJob?.cancel()
        clipboardPermissionJob = scope.launch {
            Log.i(TAG, "🔍 Starting clipboard permission check loop...")
            while (isActive) {
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
        
        Log.i(TAG, "📱 Opening clipboard permission settings...")
        runCatching { 
            startActivity(intent)
            Log.i(TAG, "✅ Settings activity started")
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

        return LanRegistrationConfig(
            serviceName = deviceIdentity.deviceId,
            port = TransportManager.DEFAULT_PORT,
            fingerprint = TransportManager.DEFAULT_FINGERPRINT,
            version = version,
            protocols = TransportManager.DEFAULT_PROTOCOLS
        )
    }

    companion object {
        private const val TAG = "ClipboardSyncService"
        private const val CHANNEL_ID = "clipboard-sync"
        private const val NOTIFICATION_ID = 42
        private const val DEFAULT_VERSION = "1.0.0"
        private const val ACTION_PAUSE = "com.hypo.clipboard.action.PAUSE"
        private const val ACTION_RESUME = "com.hypo.clipboard.action.RESUME"
        private const val ACTION_OPEN_CLIPBOARD_SETTINGS = "com.hypo.clipboard.action.OPEN_CLIPBOARD_SETTINGS"
        private const val ACTION_OPEN_ACCESSIBILITY_SETTINGS = "com.hypo.clipboard.action.OPEN_ACCESSIBILITY_SETTINGS"
        private const val ACTION_STOP = "com.hypo.clipboard.action.STOP"
    }
}
