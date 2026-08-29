package com.hypo.clipboard

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.core.view.WindowCompat
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.hypo.clipboard.service.ClipboardServiceStartReason
import com.hypo.clipboard.service.ClipboardServiceStarter
import com.hypo.clipboard.service.ClipboardSyncService
import com.hypo.clipboard.ui.history.HistoryRoute
import com.hypo.clipboard.ui.settings.SettingsRoute
import com.hypo.clipboard.ui.theme.HypoTheme
import com.hypo.clipboard.pairing.PairingRoute
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    
    // SMS permission request launcher
    private val smsPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            android.util.Log.d("MainActivity", "✅ SMS permission granted")
        } else {
            android.util.Log.w("MainActivity", "⚠️ SMS permission denied")
        }
    }
    
    // Notification permission request launcher (Android 13+)
    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            android.util.Log.d("MainActivity", "✅ Notification permission granted")
        } else {
            android.util.Log.w("MainActivity", "⚠️ Notification permission denied - persistent notification will not be shown")
        }
    }
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Request SMS permission if not granted (Android 6.0+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECEIVE_SMS) 
                != PackageManager.PERMISSION_GRANTED) {
                // Request permission
                smsPermissionLauncher.launch(Manifest.permission.RECEIVE_SMS)
            }
        }
        
        // Request notification permission if not granted (Android 13+)
        // This is required for foreground service notifications to be shown
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) 
                != PackageManager.PERMISSION_GRANTED) {
                android.util.Log.d("MainActivity", "📱 Requesting notification permission...")
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                android.util.Log.d("MainActivity", "✅ Notification permission already granted")
            }
        }
        
        // Configure status bar for white background: use dark icons and text
        // This makes status bar icons dark (visible on white background)
        val windowInsetsController = WindowCompat.getInsetsController(window, window.decorView)
        windowInsetsController.isAppearanceLightStatusBars = true
        windowInsetsController.isAppearanceLightNavigationBars = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
        
        ClipboardServiceStarter.start(this, ClipboardServiceStartReason.APP_LAUNCH)

        setContent {
            HypoTheme {
                val appBackgroundColor = MaterialTheme.colorScheme.background.toArgb()
                SideEffect {
                    window.navigationBarColor = appBackgroundColor
                }
                val navController = rememberNavController()

                Scaffold(
                    containerColor = MaterialTheme.colorScheme.background
                ) { innerPadding ->
                    NavHost(
                        navController = navController,
                        startDestination = HISTORY_ROUTE,
                        modifier = Modifier.padding(innerPadding)
                    ) {
                        composable(HISTORY_ROUTE) {
                            HistoryRoute(onOpenSettings = {
                                navController.navigate(SETTINGS_ROUTE)
                            })
                        }
                        composable(SETTINGS_ROUTE) {
                            SettingsRoute(
                                onOpenBatterySettings = ::openBatterySettings,
                                onRequestSmsPermission = ::requestSmsPermission,
                                onRequestNotificationPermission = ::requestNotificationPermission,
                                onStartPairing = { navController.navigate("pairing") }
                            )
                        }
                        composable("pairing") {
                            PairingRoute(onBack = { navController.popBackStack() })
                        }
                    }
                }
            }
        }
    }
    
    override fun onResume() {
        super.onResume()
        // Trigger clipboard check when app becomes active
        // This ensures we catch clipboard changes that occurred while app was in background
        android.util.Log.d("MainActivity", "📱 onResume - triggering clipboard check")
        ClipboardServiceStarter.start(
            context = this,
            reason = ClipboardServiceStartReason.FORCE_PROCESS,
            action = ClipboardSyncService.ACTION_FORCE_PROCESS_CLIPBOARD
        )
    }

    private fun openBatterySettings() {
        runCatching {
            // Directly open Hypo app's battery optimization settings
            // This opens the app details page where user can find battery optimization option
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            
            // Alternative: Try to directly request ignore battery optimizations
            // This shows a system dialog asking user to allow/deny
            // Only works if app doesn't already have the permission
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val powerManager = getSystemService(PowerManager::class.java)
                if (powerManager != null && !powerManager.isIgnoringBatteryOptimizations(packageName)) {
                    // App doesn't have permission yet, could show dialog
                    // But we'll let user navigate from app details page instead
                    android.util.Log.d("MainActivity", "Battery optimization not granted, opened app details page")
                }
            }
        }.onFailure { e ->
            android.util.Log.e("MainActivity", "Failed to open battery settings: ${e.message}", e)
            // Fallback: open general battery optimization settings
            runCatching {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
        }
    }
    
    private fun requestSmsPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECEIVE_SMS) 
                != PackageManager.PERMISSION_GRANTED) {
                smsPermissionLauncher.launch(Manifest.permission.RECEIVE_SMS)
            }
        }
    }
    
    private fun requestNotificationPermission() {
        // Notification permission is only required on Android 13+ (API 33+)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) 
                != PackageManager.PERMISSION_GRANTED) {
                android.util.Log.d("MainActivity", "📱 Requesting notification permission from settings...")
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                android.util.Log.d("MainActivity", "✅ Notification permission already granted")
            }
        }
    }
}

private const val HISTORY_ROUTE = "history"
private const val SETTINGS_ROUTE = "settings"
