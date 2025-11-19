package com.hypo.clipboard.ui.history

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.hypo.clipboard.R
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.transport.ConnectionState
import com.hypo.clipboard.ui.components.ConnectionStatusBadge
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun HistoryRoute(viewModel: HistoryViewModel = androidx.hilt.navigation.compose.hiltViewModel()) {
    val state by viewModel.state.collectAsState()
    HistoryScreen(
        items = state.items,
        query = state.query,
        currentDeviceId = viewModel.currentDeviceId,
        connectionState = state.connectionState,
        onQueryChange = viewModel::onQueryChange
    )
}

@Composable
fun HistoryScreen(
    items: List<ClipboardItem>,
    query: String,
    currentDeviceId: String,
    connectionState: ConnectionState,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = stringResource(id = R.string.history_title),
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold
            )
            Spacer(modifier = Modifier.weight(1f))
            ConnectionStatusBadge(connectionState = connectionState)
        }

        OutlinedTextField(
            value = query,
            onValueChange = onQueryChange,
            leadingIcon = { Icon(imageVector = Icons.Filled.Search, contentDescription = null) },
            placeholder = { Text(text = stringResource(id = R.string.history_search_hint)) },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )

        if (items.isEmpty()) {
            EmptyHistory()
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                items(items) { item ->
                    ClipboardCard(item = item, currentDeviceId = currentDeviceId)
                }
            }
        }
    }
}

@Composable
private fun EmptyHistory() {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            painter = painterResource(id = R.drawable.ic_notification),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary
        )
        Spacer(modifier = Modifier.height(12.dp))
        Text(
            text = stringResource(id = R.string.history_empty_title),
            style = MaterialTheme.typography.titleMedium
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = stringResource(id = R.string.history_empty_message),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

@Composable
private fun ClipboardCard(item: ClipboardItem, currentDeviceId: String) {
    val context = LocalContext.current
    val clipboardManager = remember {
        context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
    }
    val formatter = DateTimeFormatter.ofPattern("MMM d, HH:mm")
    val isLocal = item.deviceId == currentDeviceId
    
    // Determine origin display name: "Local" for this device, device name for paired devices
    val originName = when {
        isLocal -> "Local"
        item.deviceName != null && item.deviceName.isNotBlank() -> item.deviceName
        item.deviceId.startsWith("mac-") || 
        item.deviceId.contains("macbook", ignoreCase = true) ||
        item.deviceId.contains("imac", ignoreCase = true) ||
        !item.deviceId.startsWith("android-") -> "macOS"
        else -> item.deviceId.take(10) // Show partial ID as fallback
    }
    
    val copyToClipboard: () -> Unit = {
        val manager = clipboardManager
        if (manager != null) {
            val content = item.content
            if (content.isNotBlank()) {
                // Clipboard writes can be rejected (SecurityException) when app in background or clipboard locked,
                // so guard the call and surface a log instead of crashing the UI.
                try {
                    val clip = ClipData.newPlainText("Hypo Clipboard", content)
                    manager.setPrimaryClip(clip)
                    android.util.Log.d("HistoryScreen", "✅ Copied to clipboard: ${item.preview.take(30)}")
                } catch (e: SecurityException) {
                    android.util.Log.e("HistoryScreen", "❌ SecurityException when copying to clipboard: ${e.message}", e)
                } catch (e: IllegalStateException) {
                    android.util.Log.e("HistoryScreen", "❌ IllegalStateException when copying to clipboard: ${e.message}", e)
                } catch (e: Exception) {
                    android.util.Log.e("HistoryScreen", "❌ Failed to copy to clipboard: ${e.message}", e)
                }
            } else {
                android.util.Log.w("HistoryScreen", "⚠️ Content is blank, cannot copy")
            }
        } else {
            android.util.Log.e("HistoryScreen", "❌ ClipboardManager is null")
        }
    }
    
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                // Type icon
                Text(
                    text = item.type.icon,
                    style = MaterialTheme.typography.titleLarge
                )
                // Content title and origin badge
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    Text(
                        text = item.type.name,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold
                    )
                    // Origin badge
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = if (isLocal) 
                            MaterialTheme.colorScheme.primaryContainer 
                        else 
                            MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.padding(horizontal = 2.dp)
                    ) {
                        Text(
                            text = originName,
                            style = MaterialTheme.typography.labelSmall,
                            color = if (isLocal)
                                MaterialTheme.colorScheme.onPrimaryContainer
                            else
                                MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                        )
                    }
                }
                // Copy button
                IconButton(
                    onClick = copyToClipboard,
                    modifier = Modifier.width(40.dp)
                ) {
                    Icon(
                        imageVector = Icons.Filled.ContentCopy,
                        contentDescription = "Copy to clipboard",
                        tint = MaterialTheme.colorScheme.primary
                    )
                }
                // Timestamp
                Text(
                    text = formatter.format(item.createdAt.atZone(ZoneId.systemDefault())),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Text(
                text = item.preview,
                style = MaterialTheme.typography.bodyMedium
            )
        }
    }
}

private val ClipboardType.icon: String
    get() = when (this) {
        ClipboardType.TEXT -> "📝"
        ClipboardType.LINK -> "🔗"
        ClipboardType.IMAGE -> "🖼️"
        ClipboardType.FILE -> "📎"
    }
