package com.hypo.clipboard.ui.history

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.foundation.text.selection.SelectionContainer
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
import java.util.Base64
import androidx.compose.foundation.Image
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import kotlinx.coroutines.withContext
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.hypo.clipboard.R
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.util.SizeConstants
import com.hypo.clipboard.util.formattedAsKB
import com.hypo.clipboard.domain.model.TransportOrigin
import com.hypo.clipboard.transport.ConnectionState
import com.hypo.clipboard.ui.components.ConnectionStatusBadge
import com.hypo.clipboard.util.TempFileManager
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.CoroutineScope

@Composable
fun HistoryRoute(viewModel: HistoryViewModel = androidx.hilt.navigation.compose.hiltViewModel()) {
    val state by viewModel.state.collectAsState()
    HistoryScreen(
        items = state.items,
        query = state.query,
        currentDeviceId = viewModel.currentDeviceId,
        connectionState = state.connectionState,
        viewModel = viewModel,
        onQueryChange = viewModel::onQueryChange
    )
}

@Composable
fun HistoryScreen(
    items: List<ClipboardItem>,
    query: String,
    currentDeviceId: String,
    connectionState: ConnectionState,
    viewModel: HistoryViewModel,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val clipboardManager = remember { context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager }
    
    // Initialize TempFileManager for automatic cleanup (created once per composition)
    val tempFileManager = remember(context, scope, clipboardManager) {
        TempFileManager(
            context = context,
            scope = scope,
            clipboardManager = clipboardManager
        )
    }
    
    
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
            val listState = rememberLazyListState()
            
            // Track clicked item ID to scroll when it moves to top
            var clickedItemId by remember { mutableStateOf<String?>(null) }
            
            // Track the first item's timestamp to detect when an item moves to top
            // When an item is clicked and moved to top, its timestamp changes, triggering scroll
            val firstItemTimestamp = items.firstOrNull()?.createdAt
            val firstItemId = items.firstOrNull()?.id
            
            // Scroll to top when clicked item actually appears at index 0
            LaunchedEffect(clickedItemId, firstItemId) {
                if (clickedItemId != null && firstItemId == clickedItemId) {
                    // The clicked item is now at the top - scroll to it
                    kotlinx.coroutines.delay(100) // Small delay to ensure UI has recomposed
                    listState.animateScrollToItem(0)
                    clickedItemId = null // Clear after scrolling
                }
            }
            
            // Fallback: Scroll to top when first item changes (for new items or when timestamp changes)
            LaunchedEffect(items.size, firstItemId, firstItemTimestamp) {
                if (items.isNotEmpty() && clickedItemId == null) {
                    // Only auto-scroll if no item was clicked (to avoid conflicts)
                    kotlinx.coroutines.delay(50)
                    listState.animateScrollToItem(0)
                }
            }
            
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                items(items, key = { it.id }) { item ->
                    ClipboardCard(
                        item = item,
                        currentDeviceId = currentDeviceId,
                        viewModel = viewModel,
                        tempFileManager = tempFileManager,
                        onItemClicked = {
                            // Track the clicked item ID - we'll scroll when it appears at index 0
                            clickedItemId = item.id
                            
                            // Also set up a timeout fallback in case the item doesn't move to top
                            // (shouldn't happen, but defensive programming)
                            scope.launch {
                                kotlinx.coroutines.delay(1000) // Wait up to 1 second
                                // Check if item is at top, if not, scroll anyway
                                if (items.firstOrNull()?.id == item.id) {
                                    listState.animateScrollToItem(0)
                                } else if (clickedItemId == item.id) {
                                    // Item didn't move to top - scroll anyway as fallback
                                    listState.animateScrollToItem(0)
                                    clickedItemId = null
                                }
                            }
                        }
                    )
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
private fun ClipboardCard(
    item: ClipboardItem,
    currentDeviceId: String,
    viewModel: HistoryViewModel,
    tempFileManager: TempFileManager,
    onItemClicked: () -> Unit = {}
) {
    val context = LocalContext.current
    val clipboardManager = remember {
        context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
    }
    val formatter = DateTimeFormatter.ofPattern("MMM d, HH:mm")
    val isLocal = item.deviceId.lowercase() == currentDeviceId.lowercase()
    val scope = rememberCoroutineScope()
    // Use Job to track active copy operation - more reliable than boolean flag
    // Job state is atomic and prevents race conditions
    var copyJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    val isCopying = copyJob?.isActive == true
    
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
    // Use item.id as key to ensure we get the correct content even if item reference changes
    // For IMAGE/FILE types, content may be empty (excluded from list query to avoid CursorWindow overflow)
    // We'll load it on-demand when copying
    val contentToCopy = remember(item.id) { item.content }
    val itemId = remember(item.id) { item.id }  // Capture item ID to verify we're copying the right item
    val needsContentLoad = remember(item.id) { 
        (item.type == com.hypo.clipboard.domain.model.ClipboardType.IMAGE || 
         item.type == com.hypo.clipboard.domain.model.ClipboardType.FILE) && 
        contentToCopy.isBlank()
    }
    
    fun copyToClipboard() {
        // Prevent multiple rapid clicks by checking if job is already active
        // Job state is atomic, so this check is thread-safe
        if (copyJob?.isActive == true) {
            return
        }
        
        val manager = clipboardManager ?: return
        
        // Cancel any existing job (shouldn't happen due to check above, but defensive)
        copyJob?.cancel()
        
        // Launch new job and store it immediately - this makes isCopying true synchronously
        // The job is stored before it starts executing, preventing race conditions
        copyJob = scope.launch(Dispatchers.IO) {
            try {
                // Load content on-demand if needed (for IMAGE/FILE types that have empty content)
                var content = contentToCopy
                if (needsContentLoad) {
                    content = viewModel.loadFullContent(itemId) ?: contentToCopy
                    if (content.isBlank()) {
                        android.util.Log.w("HistoryScreen", "⚠️ Failed to load content for item ${itemId}, cannot copy")
                        // Show toast on main thread
                        kotlinx.coroutines.withContext(Dispatchers.Main) {
                            Toast.makeText(
                                context,
                                context.getString(R.string.error_content_too_large),
                                Toast.LENGTH_LONG
                            ).show()
                        }
                        return@launch
                    }
                }
                
                if (content.isBlank()) {
                    android.util.Log.w("HistoryScreen", "⚠️ Content is blank for item ${itemId}, cannot copy")
                    // Show toast on main thread
                    kotlinx.coroutines.withContext(Dispatchers.Main) {
                        Toast.makeText(
                            context,
                            context.getString(R.string.error_content_too_large),
                            Toast.LENGTH_LONG
                        ).show()
                    }
                    return@launch
                }
                
                // Size check: prevent copying very large items
                // Base64 encoding increases size by ~33%, so check the base64 string size
                val estimatedSizeBytes = (content.length * 3) / 4 // Approximate decoded size
                if (estimatedSizeBytes > SizeConstants.MAX_COPY_SIZE_BYTES) {
                    android.util.Log.w("HistoryScreen", "⚠️ Item too large to copy: ${estimatedSizeBytes.formattedAsKB()} (limit: ${SizeConstants.MAX_COPY_SIZE_BYTES.formattedAsKB()})")
                    kotlinx.coroutines.withContext(Dispatchers.Main) {
                        Toast.makeText(
                            context,
                            context.getString(R.string.error_item_too_large_to_copy, 
                                String.format("%.1f", estimatedSizeBytes / (1024.0 * 1024.0)),
                                String.format("%.0f", SizeConstants.MAX_COPY_SIZE_BYTES / (1024.0 * 1024.0))
                            ),
                            Toast.LENGTH_LONG
                        ).show()
                    }
                    return@launch
                }
        
                // Helper functions for file handling (local to this scope)
                fun createTempFileForClipboard(context: Context, bytes: ByteArray, prefix: String, suffix: String): File {
                    val tempFile = File.createTempFile(prefix, suffix, context.cacheDir)
                    FileOutputStream(tempFile).use { it.write(bytes) }
                    // Ensure file is readable
                    tempFile.setReadable(true, false)
                    return tempFile
                }
                
                fun getFileProviderUri(context: Context, file: File): android.net.Uri {
                    return androidx.core.content.FileProvider.getUriForFile(
                        context,
                        "${context.packageName}.fileprovider",
                        file
                    )
                }
                
                fun getExtensionFromFilename(filename: String): String? {
                    val lastDot = filename.lastIndexOf('.')
                    return if (lastDot >= 0 && lastDot < filename.length - 1) {
                        filename.substring(lastDot + 1).lowercase()
                    } else {
                        null
                    }
                }
                
                fun getExtensionFromMimeType(mimeType: String): String? {
                    return MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
                }
                
                val clip = when (item.type) {
                    com.hypo.clipboard.domain.model.ClipboardType.TEXT,
                    com.hypo.clipboard.domain.model.ClipboardType.LINK -> {
                        // Use "Hypo Clipboard" for all items copied from history to ensure 
                        // the change is detected and the item is moved to the top.
                        // "Hypo Remote" is reserved ONLY for automatic syncs to prevent loops.
                        val label = "Hypo Clipboard"
                        ClipData.newPlainText(label, content)
                    }
                    com.hypo.clipboard.domain.model.ClipboardType.IMAGE -> {
                        // Images: decode base64, save to temp file, create URI
                        val imageBytes = Base64.getDecoder().decode(content)
                        val format = item.metadata?.get("format") ?: "png"
                        /*
                        val mimeType = when (format.lowercase()) {
                            "png" -> "image/png"
                            "jpeg", "jpg" -> "image/jpeg"
                            "webp" -> "image/webp"
                            "gif" -> "image/gif"
                            else -> "image/png"
                        }
                        */
                        val tempFile = createTempFileForClipboard(context, imageBytes, "hypo_image", ".$format")
                        // Register temp file for automatic cleanup
                        tempFileManager.registerTempFile(tempFile)
                        val uri = getFileProviderUri(context, tempFile)
                        ClipData.newUri(context.contentResolver, "Hypo Clipboard", uri)
                    }
                    com.hypo.clipboard.domain.model.ClipboardType.FILE -> {
                        // Files: decode base64, save to temp file, create URI
                        val fileBytes = Base64.getDecoder().decode(content)
                        val filename = item.metadata?.get("file_name") ?: "file"
                        val mimeType = item.metadata?.get("mime_type") ?: "application/octet-stream"
                        val extension = getExtensionFromFilename(filename) ?: getExtensionFromMimeType(mimeType) ?: ""
                        val tempFile = createTempFileForClipboard(context, fileBytes, "hypo_file", if (extension.isNotEmpty()) ".$extension" else "")
                        // Register temp file for automatic cleanup
                        tempFileManager.registerTempFile(tempFile)
                        val uri = getFileProviderUri(context, tempFile)
                        ClipData.newUri(context.contentResolver, "Hypo Clipboard", uri)
                    }
                }
                
                // Switch to Main thread to set clipboard
                withContext(Dispatchers.Main) {
                    try {
                        // ClipData.newUri() automatically adds FLAG_GRANT_READ_URI_PERMISSION
                        // This allows the clipboard system to read the FileProvider URI
                        manager.setPrimaryClip(clip)
                        
                        // Show success toast for all types
                        Toast.makeText(
                            context,
                            context.getString(R.string.copied_to_clipboard),
                            Toast.LENGTH_SHORT
                        ).show()
                        
                        // The clipboard listener will detect the change and trigger duplicate detection,
                        // which will move the matching item to the top. No need to manually scroll -
                        // the UI will automatically update when the database changes.
                        onItemClicked()
                    } catch (e: Exception) {
                        android.util.Log.e("HistoryScreen", "❌ Error setting clipboard on main thread: ${e.message}", e)
                        Toast.makeText(
                            context,
                            context.getString(R.string.error_copying_to_clipboard, e.message ?: "Unknown error"),
                            Toast.LENGTH_LONG
                        ).show()
                        throw e // Re-throw to be caught by outer catch blocks
                    }
                }
            } catch (e: SecurityException) {
                android.util.Log.e("HistoryScreen", "❌ SecurityException when copying to clipboard: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    Toast.makeText(
                        context,
                        context.getString(R.string.error_clipboard_permission),
                        Toast.LENGTH_LONG
                    ).show()
                }
            } catch (e: IllegalStateException) {
                android.util.Log.e("HistoryScreen", "❌ IllegalStateException when copying to clipboard: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    Toast.makeText(
                        context,
                        context.getString(R.string.error_clipboard_state, e.message ?: "Unknown error"),
                        Toast.LENGTH_LONG
                    ).show()
                }
            } catch (e: Exception) {
                android.util.Log.e("HistoryScreen", "❌ Failed to copy to clipboard: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    Toast.makeText(
                        context,
                        context.getString(R.string.error_copying_to_clipboard, e.message ?: "Unknown error"),
                        Toast.LENGTH_LONG
                    ).show()
                }
            } finally {
                // Clear the job reference when done - this makes isCopying false
                copyJob = null
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
            
            // Reconstruct preview for IMAGE/FILE types if size is 0B (historical items)
            // Calculate size from metadata or content dynamically
            val displayPreview = remember(item.id, item.type, item.preview, item.metadata, item.content) {
                if (item.type == ClipboardType.IMAGE || item.type == ClipboardType.FILE) {
                    // Check if preview shows 0B (historical items with incorrect size)
                    if (item.preview.contains("(0 B)") || item.preview.contains("(0B)")) {
                        // Try to get size from metadata first
                        val sizeFromMetadata = item.metadata?.get("size")?.toLongOrNull()
                        val size = if (sizeFromMetadata != null && sizeFromMetadata > 0) {
                            sizeFromMetadata
                        } else if (item.content.isNotEmpty()) {
                            // Calculate from base64 content
                            val base64WithoutPadding = item.content.trimEnd('=')
                            (base64WithoutPadding.length * 3L / 4L)
                        } else {
                            // Try to load content to calculate size (async, will update later)
                            null
                        }
                        
                        if (size != null && size > 0) {
                            // Reconstruct preview with correct size
                            when (item.type) {
                                ClipboardType.IMAGE -> {
                                    val width = item.metadata?.get("width") ?: "?"
                                    val height = item.metadata?.get("height") ?: "?"
                                    // val format = item.metadata?.get("format") ?: "image" // format was not used
                                    "Image ${width}×${height} (${formatBytes(size)})"
                                }
                                ClipboardType.FILE -> {
                                    val filename = item.metadata?.get("file_name") ?: item.metadata?.get("filename") ?: "file"
                                    "$filename (${formatBytes(size)})"
                                }
                                else -> item.preview
                            }
                        } else {
                            item.preview // Keep original if we can't calculate
                        }
                    } else {
                        item.preview // Preview already has correct size
                    }
                } else {
                    item.preview // For TEXT/LINK, use preview as-is
                }
            }
            
            // Show preview text with magnetic icon if truncated
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = if (isTruncated) displayPreview else item.content,
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f)
                )
                if (isTruncated) {
                    if (item.type == ClipboardType.LINK) {
                        // For links, show browser icon and open URL in browser
                        IconButton(
                            onClick = {
                                try {
                                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(item.content))
                                    context.startActivity(intent)
                                } catch (e: Exception) {
                                    // If opening browser fails, fall back to detail dialog
                                    showDetailDialog = true
                                }
                            },
                            modifier = Modifier.size(24.dp)
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Link,
                                contentDescription = "Visit in Browser",
                                tint = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    } else {
                        // For other types, show visibility icon and open detail dialog
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
            }
            
            // Detail dialog
            if (showDetailDialog) {
                ModalBottomSheet(
                    onDismissRequest = { showDetailDialog = false },
                    sheetState = sheetState
                ) {
                    ClipboardDetailContent(
                        item = item,
                        viewModel = viewModel
                    )
                }
            }
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

private val ClipboardType.iconVector: androidx.compose.ui.graphics.vector.ImageVector
    get() = when (this) {
        ClipboardType.TEXT -> Icons.Outlined.TextFields
        ClipboardType.LINK -> Icons.Outlined.Link
        ClipboardType.IMAGE -> Icons.Outlined.Image
        ClipboardType.FILE -> Icons.Outlined.Description
    }

@Composable
private fun ClipboardDetailContent(
    item: ClipboardItem,
    viewModel: HistoryViewModel
) {
    val context = LocalContext.current
    
    // Load full content for IMAGE/FILE types automatically when detail view opens
    var loadedContent by remember { mutableStateOf(item.content) }
    var isLoading by remember { mutableStateOf(false) }
    var loadError by remember { mutableStateOf<String?>(null) }
    
    // Determine if content loading is needed
    val needsLoading = remember(item.type, item.content) {
        (item.type == ClipboardType.IMAGE || item.type == ClipboardType.FILE) && item.content.isEmpty()
    }

    LaunchedEffect(item.id, needsLoading) {
        if (needsLoading) {
            isLoading = true
            loadError = null
            try {
                val content = viewModel.loadFullContent(item.id)
                if (content != null && content.isNotEmpty()) {
                    loadedContent = content
                } else {
                    loadError = "Failed to load content"
                }
            } catch (e: Exception) {
                loadError = "Error loading content: ${e.message}"
            } finally {
                isLoading = false
            }
        }
    }
    
    val fileBytes = remember(loadedContent) {
        try {
            if (loadedContent.isNotEmpty() && (item.type == ClipboardType.IMAGE || item.type == ClipboardType.FILE)) {
                Base64.getDecoder().decode(loadedContent)
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }
    }

    // Determine Metadata
    val fileName = remember(item) {
        item.metadata?.get("file_name") ?: item.metadata?.get("filename") ?: 
        when (item.type) {
            ClipboardType.TEXT -> "Clipboard content"
            ClipboardType.IMAGE -> "Clipboard image"
            else -> item.type.name
        }
    }
    
    val size = remember(item, fileBytes) {
        item.metadata?.get("size")?.toLongOrNull() ?: (fileBytes?.size?.toLong()) ?: item.content.length.toLong()
    }
    
    val mimeType = remember(item) {
        item.metadata?.get("mime_type") ?: "text/plain"
    }
    
    val date = remember(item.createdAt) {
        DateTimeFormatter.ofPattern("MMM d, HH:mm").format(item.createdAt.atZone(ZoneId.systemDefault()))
    }
    
    fun getExtension(name: String): String {
        val i = name.lastIndexOf('.')
        return if (i > 0) name.substring(i + 1).lowercase() else ""
    }
    val extension = getExtension(fileName)
    
    val isImage = item.type == ClipboardType.IMAGE || mimeType.startsWith("image/")
    
    // Logic to open file
    fun openFile() {
        try {
            val bytesToSave = fileBytes ?: loadedContent.toByteArray()
            val ext = if (extension.isNotEmpty()) ".$extension" else if (item.type == ClipboardType.TEXT) ".txt" else ""
            val prefix = "hypo_open_"
            
            // Create temp file
            val tempFile = File.createTempFile(prefix, ext, context.cacheDir)
            FileOutputStream(tempFile).use { it.write(bytesToSave) }
            tempFile.setReadable(true, false)
            
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                tempFile
            )
            
            val targetMimeType = if (item.type == ClipboardType.TEXT) "text/plain" else mimeType
            
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, targetMimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(Intent.createChooser(intent, "Open with..."))
        } catch (e: Exception) {
            Toast.makeText(context, "Cannot open: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 600.dp)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // Header Row: Title + Open Button
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = fileName,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                modifier = Modifier.weight(1f)
            )
            
            Button(onClick = { openFile() }) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.OpenInNew,
                    contentDescription = "Open",
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text("Open")
            }
        }
        
        // Metadata Row
        Text(
            text = "${formatBytes(size)} • $date • ${mimeType}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        
        // Content Area
        Box(
            modifier = Modifier
                .weight(1f, fill = false)
                .fillMaxWidth()
        ) {
            val scrollState = rememberScrollState()
            
            if (isLoading) {
                Text("Loading content...", modifier = Modifier.align(Alignment.Center))
            } else if (loadError != null) {
                Text("Error: $loadError", color = MaterialTheme.colorScheme.error, modifier = Modifier.align(Alignment.Center))
            } else {
                if (isImage && fileBytes != null) {
                   val bitmap = BitmapFactory.decodeByteArray(fileBytes, 0, fileBytes.size)
                   if (bitmap != null) {
                       Image(
                           bitmap = bitmap.asImageBitmap(),
                           contentDescription = "Preview",
                           modifier = Modifier
                               .fillMaxWidth()
                               .verticalScroll(scrollState)
                       )
                   } else {
                       Text("Unable to enable image preview", modifier = Modifier.align(Alignment.Center))
                   }
                } else {
                    // Text content (or fallback for binary)
                    val textToShow = if (item.type != ClipboardType.IMAGE && item.type != ClipboardType.FILE) {
                        loadedContent
                    } else if (fileBytes != null) {
                        try {
                             // Try to decode generic file as text logic
                             val hasNull = fileBytes.any { it == 0.toByte() }
                             if (!hasNull) String(fileBytes, Charsets.UTF_8) else "Binary content. Click Open to view."
                        } catch(e: Exception) { "Binary content. Click Open to view." }
                    } else "No content"

                    SelectionContainer {
                        Text(
                            text = textToShow,
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier
                                .fillMaxWidth()
                                .verticalScroll(scrollState)
                        )
                    }
                }
            }
        }
    }
}
