package com.hypo.clipboard.ui.settings

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
import androidx.compose.material.icons.filled.Accessibility
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

@Composable
fun SettingsRoute(
    onOpenBatterySettings: () -> Unit,
    onOpenAccessibilitySettings: () -> Unit,
    onStartPairing: () -> Unit,
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val state by viewModel.state.collectAsState()
    SettingsScreen(
        state = state,
        onLanSyncChanged = viewModel::onLanSyncChanged,
        onCloudSyncChanged = viewModel::onCloudSyncChanged,
        onHistoryLimitChanged = viewModel::onHistoryLimitChanged,
        onAutoDeleteDaysChanged = viewModel::onAutoDeleteDaysChanged,
        onPlainTextModeChanged = viewModel::onPlainTextModeChanged,
        onOpenBatterySettings = onOpenBatterySettings,
        onOpenAccessibilitySettings = onOpenAccessibilitySettings,
        onStartPairing = onStartPairing,
        onRemoveDevice = viewModel::removeDevice
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    onLanSyncChanged: (Boolean) -> Unit,
    onCloudSyncChanged: (Boolean) -> Unit,
    onHistoryLimitChanged: (Int) -> Unit,
    onAutoDeleteDaysChanged: (Int) -> Unit,
    onPlainTextModeChanged: (Boolean) -> Unit,
    onOpenBatterySettings: () -> Unit,
    onOpenAccessibilitySettings: () -> Unit,
    onStartPairing: () -> Unit,
    onRemoveDevice: (DiscoveredPeer) -> Unit,
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
                    lanEnabled = state.lanSyncEnabled,
                    cloudEnabled = state.cloudSyncEnabled,
                    plainTextMode = state.plainTextModeEnabled,
                    onLanSyncChanged = onLanSyncChanged,
                    onCloudSyncChanged = onCloudSyncChanged,
                    onPlainTextModeChanged = onPlainTextModeChanged
                )
            }

            item {
                HistorySection(
                    historyLimit = state.historyLimit,
                    autoDeleteDays = state.autoDeleteDays,
                    onHistoryLimitChanged = onHistoryLimitChanged,
                    onAutoDeleteDaysChanged = onAutoDeleteDaysChanged
                )
            }

            item {
                BatterySection(onOpenBatterySettings = onOpenBatterySettings)
            }

            item {
                AccessibilitySection(
                    isEnabled = state.isAccessibilityServiceEnabled,
                    onOpenAccessibilitySettings = onOpenAccessibilitySettings
                )
            }

            item {
                DevicesSection(
                    peers = state.discoveredPeers,
                    deviceStatuses = state.deviceStatuses,
                    onStartPairing = onStartPairing,
                    onRemoveDevice = onRemoveDevice
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
                text = "Version $versionName (Build $versionCode)",
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
    lanEnabled: Boolean,
    cloudEnabled: Boolean,
    plainTextMode: Boolean,
    onLanSyncChanged: (Boolean) -> Unit,
    onCloudSyncChanged: (Boolean) -> Unit,
    onPlainTextModeChanged: (Boolean) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            text = stringResource(id = R.string.settings_sync),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold
        )
        ListItem(
            headlineContent = { Text(text = stringResource(id = R.string.settings_lan_sync)) },
            supportingContent = { Text(text = stringResource(id = R.string.settings_lan_sync_description)) },
            trailingContent = {
                Switch(checked = lanEnabled, onCheckedChange = onLanSyncChanged)
            }
        )
        Divider()
        ListItem(
            headlineContent = { Text(text = stringResource(id = R.string.settings_cloud_sync)) },
            supportingContent = { Text(text = stringResource(id = R.string.settings_cloud_sync_description)) },
            trailingContent = {
                Switch(checked = cloudEnabled, onCheckedChange = onCloudSyncChanged)
            }
        )
        Divider()
        ListItem(
            headlineContent = { Text(text = "Plain Text Mode (Debug)") },
            supportingContent = { Text(text = "⚠️ Send clipboard without encryption. Less secure, for debugging only.") },
            trailingContent = {
                Switch(checked = plainTextMode, onCheckedChange = onPlainTextModeChanged)
            }
        )
    }
}

@Composable
private fun HistorySection(
    historyLimit: Int,
    autoDeleteDays: Int,
    onHistoryLimitChanged: (Int) -> Unit,
    onAutoDeleteDaysChanged: (Int) -> Unit
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
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                text = stringResource(id = R.string.settings_auto_delete_description),
                style = MaterialTheme.typography.bodyMedium
            )
            Slider(
                value = autoDeleteDays.toFloat(),
                onValueChange = { newValue ->
                    val snapped = newValue.roundToInt().coerceIn(
                        UserSettings.MIN_AUTO_DELETE_DAYS,
                        UserSettings.MAX_AUTO_DELETE_DAYS
                    )
                    onAutoDeleteDaysChanged(snapped)
                },
                valueRange = UserSettings.MIN_AUTO_DELETE_DAYS.toFloat()..UserSettings.MAX_AUTO_DELETE_DAYS.toFloat(),
                steps = (UserSettings.MAX_AUTO_DELETE_DAYS - UserSettings.MIN_AUTO_DELETE_DAYS) - 1
            )
            val autoDeleteLabel = if (autoDeleteDays == 0) {
                stringResource(id = R.string.settings_auto_delete_never)
            } else {
                stringResource(id = R.string.settings_auto_delete_value, autoDeleteDays)
            }
            Text(
                text = autoDeleteLabel,
                style = MaterialTheme.typography.labelLarge
            )
        }
    }
}

@Composable
private fun BatterySection(onOpenBatterySettings: () -> Unit) {
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
            Button(onClick = onOpenBatterySettings, modifier = Modifier.align(Alignment.End)) {
                Text(text = stringResource(id = R.string.settings_battery_optimize_button))
            }
        }
    }
}

@Composable
private fun AccessibilitySection(
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
                Icon(imageVector = Icons.Filled.Accessibility, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = stringResource(id = R.string.settings_accessibility),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold
                )
            }
            Text(
                text = stringResource(id = R.string.settings_accessibility_description),
                style = MaterialTheme.typography.bodyMedium
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (isEnabled) {
                        stringResource(id = R.string.settings_accessibility_status_enabled)
                    } else {
                        stringResource(id = R.string.settings_accessibility_status_disabled)
                    },
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (isEnabled) {
                        MaterialTheme.colorScheme.primary
                    } else {
                        MaterialTheme.colorScheme.error
                    }
                )
                Button(onClick = onOpenAccessibilitySettings) {
                    Text(text = stringResource(id = R.string.settings_accessibility_open_button))
                }
            }
        }
    }
}

@Composable
private fun DevicesSection(
    peers: List<DiscoveredPeer>,
    deviceStatuses: Map<String, DeviceConnectionStatus>,
    onStartPairing: () -> Unit,
    onRemoveDevice: (DiscoveredPeer) -> Unit
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
                    DeviceRow(
                        peer = peer,
                        status = status,
                        onRemove = { onRemoveDevice(peer) }
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
    onRemove: () -> Unit
) {
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
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Text(
                        text = peer.serviceName,
                        style = MaterialTheme.typography.titleMedium
                    )
                    DeviceStatusBadge(status = status)
                }
                Text(
                    text = "${peer.host}:${peer.port}",
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
