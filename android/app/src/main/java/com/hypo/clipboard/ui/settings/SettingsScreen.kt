package com.hypo.clipboard.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Message
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Divider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import androidx.hilt.navigation.compose.hiltViewModel
import com.hypo.clipboard.BuildConfig
import com.hypo.clipboard.R
import com.hypo.clipboard.data.settings.UserSettings
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import com.hypo.clipboard.transport.ConnectionState
import com.hypo.clipboard.ui.components.DeviceConnectionStatus
import com.hypo.clipboard.ui.components.DeviceStatusBadge
import com.hypo.clipboard.ui.components.ConnectionStatusBadge
import com.hypo.clipboard.util.MiuiAdapter

@Composable
fun SettingsRoute(
    onOpenBatterySettings: () -> Unit,
    onRequestSmsPermission: () -> Unit,
    onRequestNotificationPermission: () -> Unit,
    onStartPairing: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val state by viewModel.state.collectAsState()
    SettingsScreen(
        state = state,
        onHistoryLimitChanged = viewModel::onHistoryLimitChanged,
        onPlainTextModeChanged = viewModel::onPlainTextModeChanged,
        onOpenBatterySettings = onOpenBatterySettings,
        onRequestSmsPermission = onRequestSmsPermission,
        onRequestNotificationPermission = onRequestNotificationPermission,
        onStartPairing = onStartPairing,
        onRemoveDevice = viewModel::removeDevice,
        onCheckPeerStatus = { viewModel.checkPeerStatus() },
        onOpenAccessibilitySettings = { viewModel.openAccessibilitySettings() }
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    onHistoryLimitChanged: (Int) -> Unit,
    onPlainTextModeChanged: (Boolean) -> Unit,
    onOpenBatterySettings: () -> Unit,
    onRequestSmsPermission: () -> Unit,
    onRequestNotificationPermission: () -> Unit,
    onStartPairing: () -> Unit,
    onRemoveDevice: (DiscoveredPeer) -> Unit,
    onCheckPeerStatus: () -> Unit,
    onOpenAccessibilitySettings: () -> Unit,
    modifier: Modifier = Modifier
) {
    Scaffold(
        topBar = {
            TopAppBar(title = { Text(text = stringResource(id = R.string.settings_title)) })
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = modifier
                .fillMaxSize()
                .padding(innerPadding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp)
        ) {
            item {
                ConnectionStatusSection(connectionState = state.connectionState)
            }
            
            item {
                SyncSection(
                    plainTextMode = state.plainTextModeEnabled,
                    onPlainTextModeChanged = onPlainTextModeChanged
                )
            }

            item {
                HistorySection(
                    historyLimit = state.historyLimit,
                    onHistoryLimitChanged = onHistoryLimitChanged
                )
            }

            item {
                BatterySection(
                    isDisabled = state.isBatteryOptimizationDisabled,
                    onOpenBatterySettings = onOpenBatterySettings
                )
            }

            item {
                SmsPermissionSection(
                    isGranted = state.isSmsPermissionGranted,
                    onRequestSmsPermission = onRequestSmsPermission
                )
            }

            item {
                NotificationPermissionSection(
                    isGranted = state.isNotificationPermissionGranted,
                    onRequestNotificationPermission = onRequestNotificationPermission
                )
            }

            item {
                AccessibilityServiceSection(
                    isEnabled = state.isAccessibilityServiceEnabled,
                    onOpenAccessibilitySettings = onOpenAccessibilitySettings
                )
            }

            item {
                DevicesSection(
                    peers = state.discoveredPeers,
                    deviceStatuses = state.deviceStatuses,
                    deviceTransports = state.deviceTransports,
                    peerDiscoveryStatus = state.peerDiscoveryStatus,
                    connectionState = state.connectionState,
                    onStartPairing = onStartPairing,
                    onRemoveDevice = onRemoveDevice,
                    onCheckPeerStatus = onCheckPeerStatus,
                    peerDeviceNames = state.peerDeviceNames
                )
            }

            item {
                AboutSection()
            }
        }
    }
}

@Composable
private fun AboutSection() {
    // Get version from BuildConfig (generated by Gradle)
    val versionName = BuildConfig.VERSION_NAME
    val versionCode = BuildConfig.VERSION_CODE.toString()
    
    // Determine build type (Debug or Release)
    val buildType = if (BuildConfig.DEBUG) "Debug" else "Release"
    val versionText = "Version $versionName-$buildType (Build $versionCode)"

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Text(
                text = "About",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )
            Text(
                text = "Hypo Clipboard",
                style = MaterialTheme.typography.bodyLarge
            )
            Text(
                text = versionText,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun ConnectionStatusSection(connectionState: ConnectionState) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = "Server Connection",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold
        )
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Status:",
                    style = MaterialTheme.typography.bodyMedium
                )
                ConnectionStatusBadge(connectionState = connectionState)
            }
        }
    }
}

@Composable
private fun SyncSection(
    plainTextMode: Boolean,
    onPlainTextModeChanged: (Boolean) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = stringResource(id = R.string.settings_sync),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold
        )
        ListItem(
            headlineContent = { Text(text = "Plain Text Mode") },
            trailingContent = {
                Switch(checked = plainTextMode, onCheckedChange = onPlainTextModeChanged)
            }
        )
    }
}

@Composable
private fun HistorySection(
    historyLimit: Int,
    onHistoryLimitChanged: (Int) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(
            text = stringResource(id = R.string.settings_history),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold
        )
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = stringResource(id = R.string.settings_history_limit_description),
                style = MaterialTheme.typography.bodyMedium
            )
            Slider(
                value = historyLimit.toFloat(),
                onValueChange = { newValue ->
                    val snapped = ((newValue / UserSettings.HISTORY_STEP).roundToInt() * UserSettings.HISTORY_STEP)
                        .coerceIn(UserSettings.MIN_HISTORY_LIMIT, UserSettings.MAX_HISTORY_LIMIT)
                    onHistoryLimitChanged(snapped)
                },
                valueRange = UserSettings.MIN_HISTORY_LIMIT.toFloat()..UserSettings.MAX_HISTORY_LIMIT.toFloat(),
                steps = ((UserSettings.MAX_HISTORY_LIMIT - UserSettings.MIN_HISTORY_LIMIT) / UserSettings.HISTORY_STEP) - 1
            )
            Text(
                text = stringResource(id = R.string.settings_history_limit_value, historyLimit),
                style = MaterialTheme.typography.labelLarge
            )
        }
    }
}

@Composable
private fun BatterySection(
    isDisabled: Boolean,
    onOpenBatterySettings: () -> Unit
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(imageVector = Icons.Filled.BatteryAlert, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = stringResource(id = R.string.settings_battery),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Text(
                text = stringResource(id = R.string.settings_battery_description),
                style = MaterialTheme.typography.bodyMedium
            )
            if (MiuiAdapter.isMiuiOrHyperOS()) {
                Text(
                    text = stringResource(id = R.string.settings_miui_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (isDisabled) {
                        stringResource(id = R.string.settings_battery_status_disabled)
                    } else {
                        stringResource(id = R.string.settings_battery_status_enabled)
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (isDisabled) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.primary
                    }
                )
                if (!isDisabled) {
                    Button(onClick = onOpenBatterySettings) {
                        Text(text = stringResource(id = R.string.settings_battery_optimize_button))
                    }
                }
            }
        }
    }
}

@Composable
private fun SmsPermissionSection(
    isGranted: Boolean,
    onRequestSmsPermission: () -> Unit
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                @Suppress("DEPRECATION")
                Icon(imageVector = Icons.Filled.Message, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = stringResource(id = R.string.settings_sms_permission),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Text(
                text = stringResource(id = R.string.settings_sms_permission_description),
                style = MaterialTheme.typography.bodyMedium
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (isGranted) {
                        stringResource(id = R.string.settings_sms_permission_status_granted)
                    } else {
                        stringResource(id = R.string.settings_sms_permission_status_denied)
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (isGranted) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.error
                    }
                )
                if (!isGranted) {
                    Button(onClick = onRequestSmsPermission) {
                        Text(text = stringResource(id = R.string.settings_sms_permission_request_button))
                    }
                }
            }
            if (!isGranted) {
                Text(
                    text = stringResource(id = R.string.settings_sms_permission_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun NotificationPermissionSection(
    isGranted: Boolean,
    onRequestNotificationPermission: () -> Unit
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                @Suppress("DEPRECATION")
                Icon(imageVector = Icons.Filled.Message, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = stringResource(id = R.string.settings_notification_permission),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Text(
                text = stringResource(id = R.string.settings_notification_permission_description),
                style = MaterialTheme.typography.bodyMedium
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (isGranted) {
                        stringResource(id = R.string.settings_notification_permission_status_granted)
                    } else {
                        stringResource(id = R.string.settings_notification_permission_status_denied)
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (isGranted) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.error
                    }
                )
                if (!isGranted) {
                    Button(onClick = onRequestNotificationPermission) {
                        Text(text = stringResource(id = R.string.settings_notification_permission_request_button))
                    }
                }
            }
            if (!isGranted) {
                Text(
                    text = stringResource(id = R.string.settings_notification_permission_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    }
}

@Composable
private fun AccessibilityServiceSection(
    isEnabled: Boolean,
    onOpenAccessibilitySettings: () -> Unit
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(imageVector = Icons.Filled.Devices, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = stringResource(id = R.string.settings_accessibility_service),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Text(
                text = stringResource(id = R.string.settings_accessibility_service_description),
                style = MaterialTheme.typography.bodyMedium
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = stringResource(
                        id = if (isEnabled) R.string.settings_accessibility_service_status_enabled
                        else R.string.settings_accessibility_service_status_disabled
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (isEnabled) MaterialTheme.colorScheme.primary
                    else MaterialTheme.colorScheme.error
                )
                if (!isEnabled) {
                    Button(onClick = onOpenAccessibilitySettings) {
                        Text(text = stringResource(id = R.string.settings_accessibility_service_enable_button))
                    }
                }
            }
            Text(
                text = stringResource(id = R.string.settings_accessibility_service_note),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun DevicesSection(
    peers: List<DiscoveredPeer>,
    deviceStatuses: Map<String, DeviceConnectionStatus>,
    deviceTransports: Map<String, com.hypo.clipboard.transport.ActiveTransport?>,
    peerDiscoveryStatus: Map<String, Boolean>,
    connectionState: com.hypo.clipboard.transport.ConnectionState,
    onStartPairing: () -> Unit,
    onRemoveDevice: (DiscoveredPeer) -> Unit,
    onCheckPeerStatus: () -> Unit = {},
    peerDeviceNames: Map<String, String?> = emptyMap()
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(imageVector = Icons.Filled.Devices, contentDescription = null)
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = stringResource(id = R.string.settings_devices),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold
            )
        }
        if (peers.isEmpty()) {
            Text(
                text = stringResource(id = R.string.settings_devices_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                peers.forEach { peer ->
                    val status = deviceStatuses[peer.serviceName] ?: DeviceConnectionStatus.Disconnected
                    val transport = deviceTransports[peer.serviceName]
                    val isDiscovered = peerDiscoveryStatus[peer.serviceName] ?: false
                    // Get device name from state (looked up from TransportManager), fall back to serviceName (Bonjour hostname)
                    val deviceName = peerDeviceNames[peer.serviceName]
                    DeviceRow(
                        peer = peer,
                        status = status,
                        transport = transport,
                        isDiscovered = isDiscovered,
                        isServerConnected = connectionState == com.hypo.clipboard.transport.ConnectionState.ConnectedCloud,
                        onRemove = { onRemoveDevice(peer) },
                        onCheckStatus = onCheckPeerStatus,
                        deviceName = deviceName
                    )
                }
            }
        }
        Button(onClick = onStartPairing) {
            Text(text = stringResource(id = R.string.pairing_scan_qr))
        }
    }
}

@Composable
private fun DeviceRow(
    peer: DiscoveredPeer,
    status: DeviceConnectionStatus,
    @Suppress("UNUSED_PARAMETER") transport: com.hypo.clipboard.transport.ActiveTransport?,
    isDiscovered: Boolean,
    @Suppress("UNUSED_PARAMETER") isServerConnected: Boolean,
    onRemove: () -> Unit,
    onCheckStatus: () -> Unit = {},
    deviceName: String? = null
) {
    // transport and isServerConnected parameters are kept for API compatibility but not currently used in UI
    // Use stored device name if available, otherwise fall back to serviceName (Bonjour hostname)
    val displayName = deviceName ?: peer.attributes["device_name"] ?: peer.serviceName
    
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onCheckStatus),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(
                        text = displayName,
                        style = MaterialTheme.typography.titleMedium
                    )
                    DeviceStatusBadge(status = status)
                }
                // Display detailed connection status or last seen based on connection status
                val addressText = when (status) {
                    DeviceConnectionStatus.ConnectedBoth -> {
                        // Connected via both LAN and Cloud
                        if (isDiscovered && peer.host != "unknown") {
                            "LAN ✓ · Cloud ✓ (${peer.host}:${peer.port} + server)"
                        } else {
                            "LAN ✓ · Cloud ✓"
                        }
                    }
                    DeviceConnectionStatus.ConnectedLan -> {
                        // Connected via LAN only
                        if (isDiscovered && peer.host != "unknown") {
                            "LAN ✓ (${peer.host}:${peer.port})"
                        } else {
                            "LAN ✓"
                        }
                    }
                    DeviceConnectionStatus.ConnectedCloud -> {
                        // Connected via Cloud only
                        "Cloud ✓"
                    }
                    else -> {
                        // Show last seen timestamp for disconnected devices
                        val lastSeen = peer.lastSeen
                        val formatter = java.time.format.DateTimeFormatter.ofPattern("M/d/yyyy h:mm a")
                        val zonedDateTime = lastSeen.atZone(java.time.ZoneId.systemDefault())
                        "Offline · Last seen ${formatter.format(zonedDateTime)}"
                    }
                }
                Text(
                    text = addressText,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            IconButton(onClick = onRemove) {
                Icon(
                    imageVector = Icons.Filled.Delete,
                    contentDescription = "Remove device",
                    tint = MaterialTheme.colorScheme.error
                )
            }
        }
    }
}
