package com.hypo.clipboard.ui.history

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.hypo.clipboard.R
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.domain.model.TransportOrigin
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

        TextField(
            value = query,
            onValueChange = onQueryChange,
            leadingIcon = { Icon(imageVector = Icons.Filled.Search, contentDescription = null) },
            placeholder = { Text(text = stringResource(id = R.string.history_search_hint)) },
            modifier = Modifier
                .fillMaxWidth()
                .height(56.dp),
            singleLine = true,
            colors = TextFieldDefaults.colors(
                unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant
            )
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ClipboardCard(item: ClipboardItem, currentDeviceId: String) {
    val context = LocalContext.current
    val clipboardManager = remember {
        context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
    }
    val formatter = DateTimeFormatter.ofPattern("MMM d, HH:mm")
    val isLocal = item.deviceId == currentDeviceId
    val scope = rememberCoroutineScope()
    var isCopying by remember { mutableStateOf(false) }
    
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
    
    // Pre-cache content to avoid accessing it during click
    val contentToCopy = remember(item.id) { item.content }
    
    fun copyToClipboard() {
        if (isCopying) return  // Prevent multiple rapid clicks
        
        val manager = clipboardManager ?: return
        val content = contentToCopy
        if (content.isBlank()) {
            android.util.Log.w("HistoryScreen", "⚠️ Content is blank, cannot copy")
            return
        }
        
        isCopying = true
        // Perform clipboard operation - setPrimaryClip must be on main thread
        // But we can make it non-blocking by using a coroutine
        scope.launch(Dispatchers.Main) {
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
            } finally {
                isCopying = false
            }
        }
    }
    
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = !isCopying, onClick = ::copyToClipboard),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                // Type icon - minimalist line-based icon
                Icon(
                    imageVector = item.type.iconVector,
                    contentDescription = item.type.name,
                    modifier = Modifier.size(20.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
                // Content title and origin badge
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    // Origin badge with cloud/encrypted info
                    Surface(
                        shape = RoundedCornerShape(12.dp),
                        color = if (isLocal) 
                            MaterialTheme.colorScheme.primaryContainer 
                        else 
                            MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.padding(horizontal = 2.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                        ) {
                            // Encryption icon (shield) - similar to macOS
                            if (item.isEncrypted) {
                                Icon(
                                    imageVector = Icons.Filled.Shield,
                                    contentDescription = "Encrypted",
                                    modifier = Modifier.size(12.dp),
                                    tint = MaterialTheme.colorScheme.primary
                                )
                            }
                            // Transport origin icon (cloud only - no icon for LAN, matching macOS)
                            if (item.transportOrigin == com.hypo.clipboard.domain.model.TransportOrigin.CLOUD) {
                                Icon(
                                    imageVector = Icons.Filled.Cloud,
                                    contentDescription = "Cloud",
                                    modifier = Modifier.size(12.dp),
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                                )
                            }
                            // Origin name
                            Text(
                                text = originName,
                                style = MaterialTheme.typography.labelSmall,
                                color = if (isLocal)
                                    MaterialTheme.colorScheme.onPrimaryContainer
                                else
                                    MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
                // Timestamp
                Text(
                    text = formatter.format(item.createdAt.atZone(ZoneId.systemDefault())),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            // Check if content is truncated (preview is shorter than content)
            // Images and files always show detail icon (they have rich content to view)
            val isTruncated = when (item.type) {
                ClipboardType.IMAGE, ClipboardType.FILE -> true
                ClipboardType.TEXT, ClipboardType.LINK -> 
                    item.content.length > item.preview.length || 
                    (item.preview.endsWith("…") && item.content.length > item.preview.length - 1)
            }
            var showDetailDialog by remember { mutableStateOf(false) }
            val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
            
            // Show preview text with magnetic icon if truncated
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (isTruncated) item.preview else item.content,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f)
                )
                if (isTruncated) {
                    IconButton(
                        onClick = { showDetailDialog = true },
                        modifier = Modifier.size(24.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Visibility,
                            contentDescription = "View Detail",
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }
            }
            
            // Detail dialog
            if (showDetailDialog) {
                ModalBottomSheet(
                    onDismissRequest = { showDetailDialog = false },
                    sheetState = sheetState
                ) {
                    ClipboardDetailContent(
                        item = item,
                        onDismiss = { showDetailDialog = false }
                    )
                }
            }
        }
    }
}

private val ClipboardType.iconVector: androidx.compose.ui.graphics.vector.ImageVector
    get() = when (this) {
        ClipboardType.TEXT -> Icons.Outlined.TextFields
        ClipboardType.LINK -> Icons.Outlined.Link
        ClipboardType.IMAGE -> Icons.Outlined.Image
        ClipboardType.FILE -> Icons.Outlined.Description
    }

@Composable
private fun FileDetailContent(item: ClipboardItem, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var isSaving by remember { mutableStateOf(false) }
    var saveError by remember { mutableStateOf<String?>(null) }
    
    val fileBytes = try {
        Base64.decode(item.content, Base64.DEFAULT)
    } catch (e: Exception) {
        null
    }
    
    val fileName = item.metadata?.get("filename") ?: "file"
    val fileSize = item.metadata?.get("size")?.toLongOrNull() ?: (fileBytes?.size?.toLong() ?: 0L)
    val mimeType = item.metadata?.get("mime_type") ?: "application/octet-stream"
    
    // Check if it's a text file
    val isTextFile = fileName.endsWith(".txt", ignoreCase = true) ||
                     fileName.endsWith(".md", ignoreCase = true) ||
                     fileName.endsWith(".json", ignoreCase = true) ||
                     fileName.endsWith(".xml", ignoreCase = true) ||
                     fileName.endsWith(".html", ignoreCase = true) ||
                     fileName.endsWith(".css", ignoreCase = true) ||
                     fileName.endsWith(".js", ignoreCase = true) ||
                     fileName.endsWith(".py", ignoreCase = true) ||
                     fileName.endsWith(".kt", ignoreCase = true) ||
                     fileName.endsWith(".java", ignoreCase = true) ||
                     fileName.endsWith(".log", ignoreCase = true) ||
                     mimeType.startsWith("text/")
    
    val fileContent = if (fileBytes != null && isTextFile) {
        try {
            String(fileBytes, Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    } else null
    
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // File info
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = fileName,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold
            )
            Text(
                text = "Size: ${formatBytes(fileSize)}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                text = "Type: $mimeType",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        
        // Save button
        Button(
            onClick = {
                if (fileBytes == null) {
                    saveError = "No file data available"
                    return@Button
                }
                
                isSaving = true
                saveError = null
                
                // For Android, we'll show a message to use the copy button
                // Full file save with SAF requires Activity context and result handling
                // which is complex in Compose. Users can copy the file data instead.
                scope.launch(Dispatchers.Main) {
                    isSaving = false
                    android.widget.Toast.makeText(
                        context,
                        "Use the copy button to copy file data",
                        android.widget.Toast.LENGTH_SHORT
                    ).show()
                }
            },
            enabled = !isSaving && fileBytes != null
        ) {
            if (isSaving) {
                Text("Saving...")
            } else {
                Text("Save File")
            }
        }
        
        if (saveError != null) {
            Text(
                text = "Error: $saveError",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error
            )
        }
        
        // Content display
        if (fileContent != null) {
            // Text file - show content
            Text(
                text = fileContent,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.fillMaxWidth()
            )
        } else if (fileBytes != null) {
            // Binary file - show hex preview
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    text = "Binary file content (hex preview):",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = hexDump(fileBytes, maxBytes = 1024),
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    modifier = Modifier.fillMaxWidth()
                )
                if (fileBytes.size > 1024) {
                    Text(
                        text = "(Showing first 1KB of ${fileBytes.size} bytes)",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        } else {
            Text(
                text = "Unable to decode file data",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

private fun formatBytes(bytes: Long): String {
    val kb = bytes / 1024.0
    val mb = kb / 1024.0
    return when {
        mb >= 1 -> String.format("%.2f MB", mb)
        kb >= 1 -> String.format("%.2f KB", kb)
        else -> "$bytes bytes"
    }
}

private fun hexDump(data: ByteArray, maxBytes: Int): String {
    val bytesToShow = minOf(data.size, maxBytes)
    val sb = StringBuilder()
    for (i in 0 until bytesToShow step 16) {
        val end = minOf(i + 16, bytesToShow)
        val chunk = data.sliceArray(i until end)
        
        // Hex representation
        val hex = chunk.joinToString(" ") { "%02x".format(it) }
        val padding = "   ".repeat(maxOf(0, 16 - chunk.size))
        
        // ASCII representation
        val ascii = chunk.joinToString("") { byte ->
            val char = byte.toInt().toChar()
            if (char.isLetterOrDigit() || char.isWhitespace() || char in "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~") {
                char.toString()
            } else {
                "."
            }
        }
        
        sb.append("%08x  $hex$padding  |$ascii|\n".format(i))
    }
    return sb.toString()
}

@Composable
private fun ClipboardDetailContent(item: ClipboardItem, onDismiss: () -> Unit) {
    val scrollState = rememberScrollState()
    
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 600.dp)
            .padding(16.dp)
            .verticalScroll(scrollState),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Header
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = item.type.name,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold
            )
            TextButton(onClick = onDismiss) {
                Text("Close")
            }
        }
        
        // Content based on type
        when (item.type) {
            ClipboardType.IMAGE -> {
                // Decode and display image
                val imageBytes = try {
                    Base64.decode(item.content, Base64.DEFAULT)
                } catch (e: Exception) {
                    null
                }
                
                if (imageBytes != null) {
                    val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                    if (bitmap != null) {
                        Image(
                            bitmap = bitmap.asImageBitmap(),
                            contentDescription = "Clipboard Image",
                            modifier = Modifier.fillMaxWidth()
                        )
                    } else {
                        Text("Failed to decode image")
                    }
                } else {
                    Text("Invalid image data")
                }
            }
            ClipboardType.TEXT, ClipboardType.LINK -> {
                Text(
                    text = item.content,
                    style = MaterialTheme.typography.bodyLarge
                )
            }
            ClipboardType.FILE -> {
                FileDetailContent(item = item, onDismiss = onDismiss)
            }
        }
    }
}
