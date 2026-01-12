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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.core.view.WindowCompat
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
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
        
        // Use startForegroundService for foreground services (required on Android 8.0+)
        val serviceIntent = Intent(this, ClipboardSyncService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        setContent {
            HypoTheme {
                val navController = rememberNavController()
                val destinations = listOf(AppDestination.History, AppDestination.Settings)
                val backStackEntry by navController.currentBackStackEntryAsState()
                val currentRoute = backStackEntry?.destination?.route ?: AppDestination.History.route

                Scaffold(
                    bottomBar = {
                        NavigationBar {
                            destinations.forEach { destination ->
                                NavigationBarItem(
                                    selected = currentRoute == destination.route,
                                    onClick = {
                                        if (currentRoute != destination.route) {
                                            navController.navigate(destination.route) {
                                                popUpTo(AppDestination.History.route)
                                                launchSingleTop = true
                                            }
                                        }
                                    },
                                    icon = {
                                        Icon(imageVector = destination.icon, contentDescription = null)
                                    },
                                    label = { Text(text = stringResource(id = destination.labelRes)) }
                                )
                            }
                        }
                    }
                ) { innerPadding ->
                    NavHost(
                        navController = navController,
                        startDestination = AppDestination.History.route,
                        modifier = Modifier.padding(innerPadding)
                    ) {
                        composable(AppDestination.History.route) {
                            HistoryRoute()
                        }
                        composable(AppDestination.Settings.route) {
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
        val serviceIntent = Intent(this, ClipboardSyncService::class.java).apply {
            action = ClipboardSyncService.ACTION_FORCE_PROCESS_CLIPBOARD
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        } catch (e: Exception) {
            android.util.Log.w("MainActivity", "⚠️ Failed to trigger clipboard check: ${e.message}")
        }
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

private sealed class AppDestination(
    val route: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    @androidx.annotation.StringRes val labelRes: Int
) {
    data object History : AppDestination("history", Icons.Filled.History, R.string.history_title)
    data object Settings : AppDestination("settings", Icons.Filled.Settings, R.string.settings_title)
}
