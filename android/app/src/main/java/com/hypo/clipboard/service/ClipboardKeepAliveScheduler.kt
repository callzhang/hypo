package com.hypo.clipboard.service

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit

object ClipboardKeepAliveScheduler {
    private const val TAG = "ClipboardKeepAlive"
    private const val PERIODIC_WORK_NAME = "clipboard-sync-service-keep-alive"
    private const val ONE_TIME_WORK_NAME = "clipboard-sync-service-restart"
    internal const val KEY_REASON = "reason"

    fun schedulePeriodic(context: Context) {
        runCatching {
            val request = PeriodicWorkRequestBuilder<ClipboardKeepAliveWorker>(
                15,
                TimeUnit.MINUTES
            )
                .setInputData(workDataOf(KEY_REASON to "periodic"))
                .setBackoffCriteria(BackoffPolicy.LINEAR, 1, TimeUnit.MINUTES)
                .addTag(PERIODIC_WORK_NAME)
                .build()

            WorkManager.getInstance(context.applicationContext)
                .enqueueUniquePeriodicWork(
                    PERIODIC_WORK_NAME,
                    ExistingPeriodicWorkPolicy.KEEP,
                    request
                )
            Log.d(TAG, "Scheduled periodic keep-alive work")
        }.onFailure { error ->
            Log.w(TAG, "Failed to schedule periodic keep-alive work: ${error.message}", error)
        }
    }

    fun enqueueOneTime(context: Context, reason: String) {
        runCatching {
            val request = OneTimeWorkRequestBuilder<ClipboardKeepAliveWorker>()
                .setInputData(workDataOf(KEY_REASON to reason))
                .setInitialDelay(10, TimeUnit.SECONDS)
                .setBackoffCriteria(BackoffPolicy.LINEAR, 1, TimeUnit.MINUTES)
                .addTag(ONE_TIME_WORK_NAME)
                .build()

            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(
                    ONE_TIME_WORK_NAME,
                    ExistingWorkPolicy.REPLACE,
                    request
                )
            Log.d(TAG, "Enqueued one-time keep-alive work: reason=$reason")
        }.onFailure { error ->
            Log.w(TAG, "Failed to enqueue one-time keep-alive work: ${error.message}", error)
        }
    }

    fun cancel(context: Context) {
        runCatching {
            val workManager = WorkManager.getInstance(context.applicationContext)
            workManager.cancelUniqueWork(ONE_TIME_WORK_NAME)
            workManager.cancelUniqueWork(PERIODIC_WORK_NAME)
            Log.d(TAG, "Cancelled keep-alive work")
        }.onFailure { error ->
            Log.w(TAG, "Failed to cancel keep-alive work: ${error.message}", error)
        }
    }
}

class ClipboardKeepAliveWorker(
    appContext: Context,
    params: WorkerParameters
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val reason = inputData.getString(ClipboardKeepAliveScheduler.KEY_REASON) ?: "unknown"
        android.util.Log.d(TAG, "Running keep-alive worker: reason=$reason")
        ClipboardServiceStarter.start(
            context = applicationContext,
            reason = ClipboardServiceStartReason.KEEP_ALIVE_WORKER,
            scheduleRecoveryOnFailure = false
        )
        return Result.success()
    }

    companion object {
        private const val TAG = "ClipboardKeepAliveWorker"
    }
}
