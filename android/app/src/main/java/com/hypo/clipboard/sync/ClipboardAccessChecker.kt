package com.hypo.clipboard.sync

import android.app.AppOpsManager
import android.content.Context
import android.os.Build
import android.os.Process
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Helper that checks whether the app is currently allowed to observe clipboard
 * changes in the background. Android 10+ blocks clipboard access for background
 * apps unless the user explicitly grants the "Allow clipboard access" toggle.
 */
@Singleton
class ClipboardAccessChecker @Inject constructor(
    @ApplicationContext private val context: Context
) {

    fun canReadClipboard(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            android.util.Log.d(TAG, "📋 API < 29, clipboard access always allowed")
            return true
        }
        val appOps = context.getSystemService(AppOpsManager::class.java) ?: run {
            android.util.Log.w(TAG, "⚠️ AppOpsManager not available, assuming allowed")
            return true
        }
        val uid = Process.myUid()
        val packageName = context.packageName

        // Check clipboard access permission
        // On Android 10+, this checks both foreground and background access
        // The OS will enforce background restrictions separately if needed
        val opCandidates = listOf("android:read_clipboard", "android:read_clipboard_in_background")
        opCandidates.forEach { op ->
            try {
                val mode = appOps.unsafeCheckOpNoThrow(op, uid, packageName)
                val allowed = mode == AppOpsManager.MODE_ALLOWED
                android.util.Log.d(TAG, "📋 Clipboard permission check ($op): mode=$mode, allowed=$allowed (package=$packageName, uid=$uid)")
                return allowed
            } catch (illegal: IllegalArgumentException) {
                android.util.Log.w(TAG, "⚠️ Clipboard op not supported ($op): ${illegal.message}")
            } catch (error: Exception) {
                android.util.Log.w(TAG, "⚠️ Clipboard permission check failed for op $op: ${error.message}")
            }
        }
        android.util.Log.w(TAG, "⚠️ No clipboard op supported, assuming allowed")
        return true
    }
    
    companion object {
        private const val TAG = "ClipboardAccessChecker"
    }
}
