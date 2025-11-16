package com.hypo.clipboard.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.hypo.clipboard.R
import com.hypo.clipboard.data.ClipboardRepository
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
    private lateinit var screenStateReceiver: ScreenStateReceiver

    override fun onCreate() {
        super.onCreate()
        android.util.Log.i("ClipboardSyncService", "🚀🚀🚀 SERVICE onCreate() CALLED! Starting initialization...")
        notificationManager = NotificationManagerCompat.from(this)
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        android.util.Log.i("ClipboardSyncService", "✅ Service started foreground with notification")

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
            }
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val statusText = when {
            awaitingClipboardPermission -> getString(R.string.service_notification_status_permission)
            isPaused -> getString(R.string.service_notification_status_paused)
            else -> getString(R.string.service_notification_status_active)
        }
        val previewText = when {
            awaitingClipboardPermission -> getString(R.string.service_notification_permission_body)
            else -> latestPreview ?: getString(R.string.service_notification_text)
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.service_notification_title))
            .setContentText(previewText)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(previewText)
                    .setSummaryText(statusText)
            )

        if (awaitingClipboardPermission) {
            builder.addAction(
                R.drawable.ic_notification,
                getString(R.string.action_grant_clipboard_access),
                pendingIntentForAction(ACTION_OPEN_CLIPBOARD_SETTINGS)
            )
        } else if (isPaused) {
            builder.addAction(
                R.drawable.ic_notification,
                getString(R.string.action_resume),
                pendingIntentForAction(ACTION_RESUME)
            )
        } else {
            builder.addAction(
                R.drawable.ic_notification,
                getString(R.string.action_pause),
                pendingIntentForAction(ACTION_PAUSE)
            )
        }

        builder.addAction(
            R.drawable.ic_notification,
            getString(R.string.action_stop),
            pendingIntentForAction(ACTION_STOP)
        )

        return builder.build()
    }

    private fun updateNotification() {
        notificationManager.notify(NOTIFICATION_ID, buildNotification())
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
        val intent = Intent(this, ClipboardSyncService::class.java).setAction(action)
        return PendingIntent.getService(
            this,
            action.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
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
        val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = android.net.Uri.fromParts("package", packageName, null)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { startActivity(intent) }
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
        private const val ACTION_STOP = "com.hypo.clipboard.action.STOP"
    }
}
