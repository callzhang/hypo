package com.hypo.clipboard

import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.hypo.clipboard.service.ClipboardSyncService
import com.hypo.clipboard.ui.history.HistoryRoute
import com.hypo.clipboard.ui.home.HomeRoute
import com.hypo.clipboard.ui.settings.SettingsRoute
import com.hypo.clipboard.ui.theme.HypoTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startService(Intent(this, ClipboardSyncService::class.java))

        setContent {
            HypoTheme {
                val navController = rememberNavController()
                val destinations = listOf(AppDestination.Home, AppDestination.History, AppDestination.Settings)
                val backStackEntry by navController.currentBackStackEntryAsState()
                val currentRoute = backStackEntry?.destination?.route ?: AppDestination.Home.route

                Scaffold(
                    bottomBar = {
                        NavigationBar {
                            destinations.forEach { destination ->
                                NavigationBarItem(
                                    selected = currentRoute == destination.route,
                                    onClick = {
                                        if (currentRoute != destination.route) {
                                            navController.navigate(destination.route) {
                                                popUpTo(AppDestination.Home.route)
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
                        startDestination = AppDestination.Home.route,
                        modifier = Modifier.padding(innerPadding)
                    ) {
                        composable(AppDestination.Home.route) {
                            HomeRoute(
                                onViewHistory = { navController.navigate(AppDestination.History.route) },
                                onOpenSettings = { navController.navigate(AppDestination.Settings.route) }
                            )
                        }
                        composable(AppDestination.History.route) {
                            HistoryRoute()
                        }
                        composable(AppDestination.Settings.route) {
                            SettingsRoute(onOpenBatterySettings = ::openBatterySettings)
                        }
                    }
                }
            }
        }
    }

    private fun openBatterySettings() {
        runCatching {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }
}

private sealed class AppDestination(
    val route: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    @androidx.annotation.StringRes val labelRes: Int
) {
    data object Home : AppDestination("home", Icons.Filled.Home, R.string.home_title)
    data object History : AppDestination("history", Icons.Filled.History, R.string.history_title)
    data object Settings : AppDestination("settings", Icons.Filled.Settings, R.string.settings_title)
}
