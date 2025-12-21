package com.hypo.clipboard.util

/**
 * Centralized logging constants for consistent log filtering across debug and release builds.
 * 
 * Android debug and release builds use the same application ID (com.hypo.clipboard),
 * allowing them to share the same database. This also matches macOS subsystem behavior.
 * 
 * When filtering logs with adb logcat, use:
 *   adb logcat "com.hypo.clipboard:D"
 */
object LogConstants {
    /**
     * Consistent subsystem name for log filtering, matching macOS subsystem "com.hypo.clipboard".
     * Use this for logcat filtering commands that work for both debug and release builds.
     */
    const val SUBSYSTEM = "com.hypo.clipboard"
}

