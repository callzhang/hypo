package com.hypo.clipboard.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.outlined.SyncProblem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.hypo.clipboard.R
import com.hypo.clipboard.transport.ConnectionState

@Composable
fun ConnectionStatusBadge(connectionState: ConnectionState, modifier: Modifier = Modifier) {
    val visuals = when (connectionState) {
        ConnectionState.ConnectedLan -> StatusVisuals(
            icon = Icons.Filled.Wifi,
            textRes = R.string.status_lan,
            containerColor = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer
        )
        ConnectionState.ConnectedCloud -> StatusVisuals(
            icon = Icons.Filled.Cloud,
            textRes = R.string.status_cloud,
            containerColor = androidx.compose.ui.graphics.Color(0xFF2196F3), // Blue for cloud
            contentColor = androidx.compose.ui.graphics.Color.White
        )
        ConnectionState.ConnectingLan, ConnectionState.ConnectingCloud -> StatusVisuals(
            icon = Icons.Filled.Sync,
            textRes = R.string.status_connecting,
            containerColor = MaterialTheme.colorScheme.tertiaryContainer,
            contentColor = MaterialTheme.colorScheme.onTertiaryContainer
        )
        ConnectionState.Error -> StatusVisuals(
            icon = Icons.Outlined.SyncProblem,
            textRes = R.string.status_disconnected,
            containerColor = MaterialTheme.colorScheme.errorContainer,
            contentColor = MaterialTheme.colorScheme.onErrorContainer
        )
        ConnectionState.Idle -> StatusVisuals(
            icon = Icons.Filled.CloudOff,
            textRes = R.string.status_disconnected,
            containerColor = MaterialTheme.colorScheme.surfaceVariant,
            contentColor = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }

    Row(
        modifier = modifier
            .background(visuals.containerColor, RoundedCornerShape(16.dp))
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Icon(imageVector = visuals.icon, contentDescription = null, tint = visuals.contentColor)
        Text(
            text = stringResource(id = visuals.textRes),
            style = MaterialTheme.typography.labelMedium,
            color = visuals.contentColor
        )
    }
}

private data class StatusVisuals(
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val textRes: Int,
    val containerColor: androidx.compose.ui.graphics.Color,
    val contentColor: androidx.compose.ui.graphics.Color
)
