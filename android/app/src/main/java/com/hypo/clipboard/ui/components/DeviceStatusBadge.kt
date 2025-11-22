package com.hypo.clipboard.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.outlined.Error
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.hypo.clipboard.R
import com.hypo.clipboard.transport.ActiveTransport

enum class DeviceConnectionStatus {
    ConnectedLan,
    ConnectedCloud,
    Paired,
    Disconnected,
    Failed
}

@Composable
fun DeviceStatusBadge(
    status: DeviceConnectionStatus,
    modifier: Modifier = Modifier
) {
    val visuals = when (status) {
        DeviceConnectionStatus.ConnectedLan -> DeviceStatusVisuals(
            icon = Icons.Filled.Wifi,
            textRes = R.string.device_status_lan,
            containerColor = Color(0xFF4CAF50), // Green
            contentColor = Color.White
        )
        DeviceConnectionStatus.ConnectedCloud -> DeviceStatusVisuals(
            icon = Icons.Filled.Cloud,
            textRes = R.string.device_status_cloud,
            containerColor = Color(0xFF2196F3), // Blue
            contentColor = Color.White
        )
        DeviceConnectionStatus.Paired -> DeviceStatusVisuals(
            icon = Icons.Filled.Wifi,
            textRes = R.string.device_status_paired,
            containerColor = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer
        )
        DeviceConnectionStatus.Disconnected -> DeviceStatusVisuals(
            icon = Icons.Outlined.CloudOff,
            textRes = R.string.device_status_disconnected,
            containerColor = MaterialTheme.colorScheme.surfaceVariant,
            contentColor = MaterialTheme.colorScheme.onSurfaceVariant
        )
        DeviceConnectionStatus.Failed -> DeviceStatusVisuals(
            icon = Icons.Outlined.Error,
            textRes = R.string.device_status_failed,
            containerColor = MaterialTheme.colorScheme.errorContainer,
            contentColor = MaterialTheme.colorScheme.onErrorContainer
        )
    }

    Row(
        modifier = modifier
            .background(visuals.containerColor, RoundedCornerShape(12.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)
    ) {
        Icon(
            imageVector = visuals.icon,
            contentDescription = null,
            tint = visuals.contentColor,
            modifier = Modifier.size(14.dp)
        )
        // Text removed - only show icon for peer status badges
    }
}

@Composable
fun DeviceStatusIndicator(
    status: DeviceConnectionStatus,
    modifier: Modifier = Modifier
) {
    val color = when (status) {
        DeviceConnectionStatus.ConnectedLan -> Color(0xFF4CAF50) // Green
        DeviceConnectionStatus.ConnectedCloud -> Color(0xFF2196F3) // Blue
        DeviceConnectionStatus.Paired -> MaterialTheme.colorScheme.primary
        DeviceConnectionStatus.Disconnected -> MaterialTheme.colorScheme.onSurfaceVariant
        DeviceConnectionStatus.Failed -> MaterialTheme.colorScheme.error
    }

    androidx.compose.foundation.layout.Box(
        modifier = modifier
            .size(8.dp)
            .background(color, CircleShape)
    )
}

private data class DeviceStatusVisuals(
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val textRes: Int,
    val containerColor: Color,
    val contentColor: Color
)

