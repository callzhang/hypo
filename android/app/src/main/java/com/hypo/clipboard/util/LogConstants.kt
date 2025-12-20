package com.hypo.clipboard.util

/**
 * Centralized logging constants for consistent log filtering across debug and release builds.
 * 
 * Android uses different application IDs for debug (com.hypo.clipboard.debug) and release (com.hypo.clipboard),
 * but we use a consistent subsystem name "com.hypo.clipboard" for log filtering, matching macOS behavior.
 * 
 * When filtering logs with adb logcat, always include both tags to support both build types:
 *   adb logcat "com.hypo.clipboard.debug:D" "com.hypo.clipboard:D"
 */
object LogConstants {
    /**
     * Consistent subsystem name for log filtering, matching macOS subsystem "com.hypo.clipboard".
     * Use this for logcat filtering commands that should work for both debug and release builds.
     */
    const val SUBSYSTEM = "com.hypo.clipboard"
    
    /**
     * Debug build tag (includes .debug suffix from applicationIdSuffix)
     */
    const val SUBSYSTEM_DEBUG = "com.hypo.clipboard.debug"
    
    /**
     * Release build tag (base application ID)
     */
    const val SUBSYSTEM_RELEASE = "com.hypo.clipboard"
}

