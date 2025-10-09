package com.hypo.clipboard.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancelChildren
import javax.inject.Inject

@AndroidEntryPoint
class ClipboardSyncService : Service() {

    @Inject lateinit var syncCoordinator: SyncCoordinator
    @Inject lateinit var transportManager: TransportManager
    @Inject lateinit var deviceIdentity: DeviceIdentity
    @Inject lateinit var repository: ClipboardRepository

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var listener: ClipboardListener
    private lateinit var notificationManager: NotificationManagerCompat
    private var notificationJob: Job? = null
    private var latestPreview: String? = null
    private var isPaused: Boolean = false

    override fun onCreate() {
        super.onCreate()
        notificationManager = NotificationManagerCompat.from(this)
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())

        val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        listener = ClipboardListener(
            clipboardManager = clipboardManager,
            parser = ClipboardParser(contentResolver),
            onClipboardChanged = { event ->
                syncCoordinator.onClipboardEvent(event)
            },
            scope = scope
        )

        syncCoordinator.start(scope)
        transportManager.start(buildLanRegistrationConfig())
        listener.start()
        observeLatestItem()
    }

    override fun onDestroy() {
        notificationJob?.cancel()
        listener.stop()
        syncCoordinator.stop()
        transportManager.stop()
        scope.coroutineContext.cancelChildren()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> pauseListener()
            ACTION_RESUME -> resumeListener()
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
        val statusText = if (isPaused) {
            getString(R.string.service_notification_status_paused)
        } else {
            getString(R.string.service_notification_status_active)
        }
        val previewText = latestPreview ?: getString(R.string.service_notification_text)

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

        if (isPaused) {
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
        listener.start()
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
        private const val CHANNEL_ID = "clipboard-sync"
        private const val NOTIFICATION_ID = 42
        private const val DEFAULT_VERSION = "1.0.0"
        private const val ACTION_PAUSE = "com.hypo.clipboard.action.PAUSE"
        private const val ACTION_RESUME = "com.hypo.clipboard.action.RESUME"
        private const val ACTION_STOP = "com.hypo.clipboard.action.STOP"
    }
}
