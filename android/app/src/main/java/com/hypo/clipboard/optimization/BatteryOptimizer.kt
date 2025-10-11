package com.hypo.clipboard.optimization

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.PowerManager
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * Battery optimization manager that adjusts system behavior based on battery state
 * and device usage patterns to minimize power consumption.
 */
@Singleton
class BatteryOptimizer @Inject constructor(
    private val context: Context
) {
    private val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    
    private var _optimizationLevel = MutableStateFlow(OptimizationLevel.BALANCED)
    val optimizationLevel: StateFlow<OptimizationLevel> = _optimizationLevel.asStateFlow()
    
    private var monitoringJob: Job? = null
    
    fun startMonitoring(scope: CoroutineScope) {
        monitoringJob?.cancel()
        monitoringJob = scope.launch {
            while (isActive) {
                updateOptimizationLevel()
                delay(30.seconds) // Check every 30 seconds
            }
        }
    }
    
    fun stopMonitoring() {
        monitoringJob?.cancel()
    }
    
    private suspend fun updateOptimizationLevel() {
        val level = when {
            isLowBattery() && isPowerSaveMode() -> OptimizationLevel.AGGRESSIVE
            isLowBattery() || isPowerSaveMode() -> OptimizationLevel.CONSERVATIVE
            isAppInBackground() -> OptimizationLevel.CONSERVATIVE
            else -> OptimizationLevel.BALANCED
        }
        _optimizationLevel.value = level
    }
    
    private fun isLowBattery(): Boolean {
        // Consider battery low if < 20%
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            val batteryManager = context.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
            val level = batteryManager.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
            level < 20
        } else {
            false
        }
    }
    
    private fun isPowerSaveMode(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            powerManager.isPowerSaveMode
        } else {
            false
        }
    }
    
    private fun isAppInBackground(): Boolean {
        return try {
            val runningAppProcesses = activityManager.runningAppProcesses
            val currentProcess = runningAppProcesses.find { it.pid == android.os.Process.myPid() }
            currentProcess?.importance != ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        } catch (e: Exception) {
            // Default to assuming background if we can't determine
            true
        }
    }
    
    fun getClipboardMonitorInterval(): Duration {
        return when (_optimizationLevel.value) {
            OptimizationLevel.PERFORMANCE -> 100.seconds.inWholeMilliseconds.let { Duration.milliseconds(it) }
            OptimizationLevel.BALANCED -> 500.seconds.inWholeMilliseconds.let { Duration.milliseconds(it) }
            OptimizationLevel.CONSERVATIVE -> 2.seconds
            OptimizationLevel.AGGRESSIVE -> 5.seconds
        }
    }
    
    fun getNetworkRetryDelay(): Duration {
        return when (_optimizationLevel.value) {
            OptimizationLevel.PERFORMANCE -> 1.seconds
            OptimizationLevel.BALANCED -> 2.seconds
            OptimizationLevel.CONSERVATIVE -> 5.seconds
            OptimizationLevel.AGGRESSIVE -> 10.seconds
        }
    }
    
    fun getDatabaseMaintenanceInterval(): Duration {
        return when (_optimizationLevel.value) {
            OptimizationLevel.PERFORMANCE -> 5.minutes
            OptimizationLevel.BALANCED -> 15.minutes
            OptimizationLevel.CONSERVATIVE -> 30.minutes
            OptimizationLevel.AGGRESSIVE -> 60.minutes
        }
    }
    
    fun shouldReduceBackgroundWork(): Boolean {
        return _optimizationLevel.value in setOf(OptimizationLevel.CONSERVATIVE, OptimizationLevel.AGGRESSIVE)
    }
    
    fun getMaxHistorySize(): Int {
        return when (_optimizationLevel.value) {
            OptimizationLevel.PERFORMANCE -> 500
            OptimizationLevel.BALANCED -> 200
            OptimizationLevel.CONSERVATIVE -> 100
            OptimizationLevel.AGGRESSIVE -> 50
        }
    }
}

enum class OptimizationLevel {
    PERFORMANCE,    // High resource usage, best responsiveness
    BALANCED,       // Default mode, good balance
    CONSERVATIVE,   // Reduced resource usage
    AGGRESSIVE      // Minimal resource usage, may impact functionality
}