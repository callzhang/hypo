package com.hypo.clipboard.util

import android.content.Context
import android.os.Build
import android.util.Log
import java.lang.reflect.Method

/**
 * Utility class for MIUI/HyperOS specific adaptations and workarounds.
 * 
 * MIUI/HyperOS has several restrictions that affect app behavior:
 * - Aggressive background service killing
 * - Multicast throttling after ~15 minutes of screen-off time
 * - Stricter battery optimization policies
 * - Additional autostart requirements
 */
object MiuiAdapter {
    private const val TAG = "MiuiAdapter"
    
    /**
     * Check if the device is running MIUI or HyperOS.
     * 
     * Detection methods:
     * 1. Check Build.MANUFACTURER for "Xiaomi"
     * 2. Check system properties for MIUI/HyperOS indicators
     */
    fun isMiuiOrHyperOS(): Boolean {
        // Method 1: Check manufacturer
        if (Build.MANUFACTURER.equals("Xiaomi", ignoreCase = true)) {
            return true
        }
        
        // Method 2: Check system properties (MIUI/HyperOS specific)
        return try {
            val systemProperties = Class.forName("android.os.SystemProperties")
            val getMethod: Method = systemProperties.getMethod("get", String::class.java, String::class.java)
            
            // Check for MIUI version property
            val miuiVersion = getMethod.invoke(null, "ro.miui.ui.version.name", "") as? String
            val miuiVersionCode = getMethod.invoke(null, "ro.miui.ui.version.code", "") as? String
            
            // Check for HyperOS indicator
            val hyperOSVersion = getMethod.invoke(null, "ro.product.mod_device", "") as? String
            
            val isMiui = !miuiVersion.isNullOrEmpty() || !miuiVersionCode.isNullOrEmpty()
            val isHyperOS = hyperOSVersion?.contains("hyper", ignoreCase = true) == true
            
            isMiui || isHyperOS
        } catch (e: Exception) {
            // If reflection fails, fall back to manufacturer check
            Log.d(TAG, "Failed to check system properties: ${e.message}")
            false
        }
    }
    
    /**
     * Check if device is specifically running HyperOS (newer MIUI).
     */
    fun isHyperOS(): Boolean {
        if (!isMiuiOrHyperOS()) {
            return false
        }
        
        return try {
            val systemProperties = Class.forName("android.os.SystemProperties")
            val getMethod: Method = systemProperties.getMethod("get", String::class.java, String::class.java)
            val hyperOSVersion = getMethod.invoke(null, "ro.product.mod_device", "") as? String
            hyperOSVersion?.contains("hyper", ignoreCase = true) == true
        } catch (e: Exception) {
            // Fallback: Check Android version (HyperOS typically runs on Android 13+)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        }
    }
    
    /**
     * Get MIUI/HyperOS version string for logging/debugging.
     */
    fun getMiuiVersion(): String? {
        if (!isMiuiOrHyperOS()) {
            return null
        }
        
        return try {
            val systemProperties = Class.forName("android.os.SystemProperties")
            val getMethod: Method = systemProperties.getMethod("get", String::class.java, String::class.java)
            
            val miuiVersion = getMethod.invoke(null, "ro.miui.ui.version.name", "") as? String
            val hyperOSVersion = getMethod.invoke(null, "ro.product.mod_device", "") as? String
            
            when {
                !hyperOSVersion.isNullOrEmpty() -> "HyperOS $hyperOSVersion"
                !miuiVersion.isNullOrEmpty() -> "MIUI $miuiVersion"
                else -> "MIUI/HyperOS (version unknown)"
            }
        } catch (e: Exception) {
            "MIUI/HyperOS (detection failed)"
        }
    }
    
    /**
     * Check if battery optimization is disabled for the app.
     * On MIUI/HyperOS, this is critical for background service operation.
     */
    fun isBatteryOptimizationDisabled(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true // No battery optimization on older Android
        }
        
        return try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            val packageName = context.packageName
            powerManager.isIgnoringBatteryOptimizations(packageName)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to check battery optimization status: ${e.message}")
            false
        }
    }
    
    /**
     * Get recommended multicast lock refresh interval for MIUI/HyperOS.
     * HyperOS throttles multicast after ~15 minutes of screen-off time.
     * 
     * @return Refresh interval in milliseconds, or null if not MIUI/HyperOS
     */
    fun getRecommendedMulticastLockRefreshInterval(): Long? {
        if (!isMiuiOrHyperOS()) {
            return null
        }
        
        // Refresh multicast lock every 10 minutes to prevent HyperOS throttling
        // This is more aggressive than the 15-minute throttle window
        return 10 * 60 * 1000L // 10 minutes
    }
    
    /**
     * Get recommended NSD discovery restart interval for MIUI/HyperOS.
     * More frequent restarts help work around multicast throttling.
     * 
     * @return Restart interval in milliseconds, or null if not MIUI/HyperOS
     */
    fun getRecommendedNsdRestartInterval(): Long? {
        if (!isMiuiOrHyperOS()) {
            return null
        }
        
        // Restart NSD discovery every 5 minutes on MIUI/HyperOS
        // This helps recover from multicast throttling
        return 5 * 60 * 1000L // 5 minutes
    }
    
    /**
     * Log device information for debugging MIUI/HyperOS issues.
     */
    fun logDeviceInfo() {
        if (isMiuiOrHyperOS()) {
            val version = getMiuiVersion() ?: "Unknown"
            Log.i(TAG, "📱 MIUI/HyperOS Device Detected:")
            Log.i(TAG, "   Manufacturer: ${Build.MANUFACTURER}")
            Log.i(TAG, "   Model: ${Build.MODEL}")
            Log.i(TAG, "   Version: $version")
            Log.i(TAG, "   Android SDK: ${Build.VERSION.SDK_INT}")
            Log.i(TAG, "   Is HyperOS: ${isHyperOS()}")
        } else {
            Log.d(TAG, "📱 Non-MIUI device: ${Build.MANUFACTURER} ${Build.MODEL}")
        }
    }
}


