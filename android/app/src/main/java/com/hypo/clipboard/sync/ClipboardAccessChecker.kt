package com.hypo.clipboard.sync

import android.app.AppOpsManager
import android.content.Context
import android.os.Build
import android.os.Process
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject

/**
 * Helper that checks whether the app is currently allowed to observe clipboard
 * changes in the background. Android 10+ blocks clipboard access for background
 * apps unless the user explicitly grants the "Allow clipboard access" toggle.
 */
class ClipboardAccessChecker @Inject constructor(
    @ApplicationContext private val context: Context
) {

    fun canReadClipboard(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return true
        }
        val appOps = context.getSystemService(AppOpsManager::class.java) ?: return true
        val uid = Process.myUid()
        val packageName = context.packageName

        val ops = mutableListOf(AppOpsManager.OPSTR_READ_CLIPBOARD)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ops += AppOpsManager.OPSTR_READ_CLIPBOARD_IN_BACKGROUND
        }

        ops.forEach { op ->
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(op, uid, packageName)
            } else {
                AppOpsManager.MODE_ALLOWED
            }
            if (mode != AppOpsManager.MODE_ALLOWED) {
                return false
            }
        }
        return true
    }
}
