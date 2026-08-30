package com.hypo.clipboard

import android.graphics.Color
import android.os.Build
import android.view.Window
import androidx.core.view.WindowCompat

internal fun configureEdgeToEdgeWindow(window: Window) {
    WindowCompat.setDecorFitsSystemWindows(window, false)
    window.statusBarColor = Color.TRANSPARENT
    window.navigationBarColor = Color.TRANSPARENT
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        window.isNavigationBarContrastEnforced = false
    }
}
