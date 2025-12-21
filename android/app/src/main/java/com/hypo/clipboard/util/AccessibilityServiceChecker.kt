package com.hypo.clipboard.util

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.view.accessibility.AccessibilityManager
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Helper to check if the ClipboardAccessibilityService is enabled.
 * This service allows the app to access and modify clipboard in background on Android 10+.
 */
@Singleton
class AccessibilityServiceChecker @Inject constructor(
    @ApplicationContext private val context: Context
) {
    /**
     * Checks if ClipboardAccessibilityService is enabled.
     * Returns true if the service is enabled and running.
     */
    fun isAccessibilityServiceEnabled(): Boolean {
        val accessibilityManager = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
            ?: return false
        
        val enabledServices = accessibilityManager.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_GENERIC)
        val serviceName = "com.hypo.clipboard.service.ClipboardAccessibilityService"
        
        return enabledServices.any { it.resolveInfo.serviceInfo.name == serviceName }
    }
    
    companion object {
        private const val TAG = "AccessibilityServiceChecker"
    }
}


