package com.hypo.clipboard.sync

import android.content.ClipData
import android.content.ClipDescription
import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Patterns
import androidx.annotation.VisibleForTesting
import com.hypo.clipboard.domain.model.ClipboardType
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.text.DecimalFormat
import java.time.Instant
import java.util.Base64
import java.util.Locale
import kotlin.collections.buildMap
import kotlin.math.roundToInt
import kotlin.math.max
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.webkit.MimeTypeMap
import com.hypo.clipboard.util.SizeConstants

private val base64Encoder = Base64.getEncoder().withoutPadding()

class ClipboardParser(
    private val contentResolver: ContentResolver,
    private val storageManager: com.hypo.clipboard.data.local.StorageManager,
    private val onFileTooLarge: ((String, Long) -> Unit)? = null // Callback for file size warnings
) {
    // Track seen image hashes to prevent saving duplicates
    // Using a companion object so it's shared across all parser instances
    companion object {
        val seenImageHashes = mutableSetOf<String>() // Made accessible for external clearing
        val hashLock = Any() // Make accessible for external clearing
        // Track last clipboard URI to avoid reading bytes if URI hasn't changed
        @Volatile
        var lastImageUri: Uri? = null // Make accessible for external clearing
        @Volatile
        var lastImageHash: String? = null // Make accessible for external clearing
    }

    fun parse(clipData: ClipData): ClipboardEvent? {
        return try {
            if (clipData.itemCount == 0) return null
            val description = clipData.description
            for (index in 0 until clipData.itemCount) {
                val item = clipData.getItemAt(index)
                try {
                    parseFromUri(description, item)?.let { return it }
                } catch (e: SecurityException) {
                    // Android 10+ may block clipboard access in background
                    android.util.Log.d("ClipboardParser", "🔒 parseFromUri: Clipboard access blocked: ${e.message}")
                } catch (e: Exception) {
                    android.util.Log.w("ClipboardParser", "⚠️ Error in parseFromUri: ${e.message}", e)
                }
                try {
                    parseLink(item)?.let { return it }
                } catch (e: SecurityException) {
                    android.util.Log.d("ClipboardParser", "🔒 parseLink: Clipboard access blocked: ${e.message}")
                } catch (e: Exception) {
                    android.util.Log.w("ClipboardParser", "⚠️ Error in parseLink: ${e.message}", e)
                }
                try {
                    parseText(item)?.let { return it }
                } catch (e: SecurityException) {
                    android.util.Log.d("ClipboardParser", "🔒 parseText: Clipboard access blocked: ${e.message}")
                } catch (e: Exception) {
                    android.util.Log.w("ClipboardParser", "⚠️ Error in parseText: ${e.message}", e)
                }
            }
            null
        } catch (e: SecurityException) {
            android.util.Log.d("ClipboardParser", "🔒 parse: Clipboard access blocked: ${e.message}")
            null
        } catch (e: Exception) {
            android.util.Log.e("ClipboardParser", "❌ Error in parse: ${e.message}", e)
            null
        }
    }

    private fun parseFromUri(description: ClipDescription, item: ClipData.Item): ClipboardEvent? {
        val uri = item.uri ?: return null
        val scheme = uri.scheme?.lowercase(Locale.US)
        if (scheme == "http" || scheme == "https") {
            return parseLinkFromUri(uri)
        }

        val mimeType = resolveMimeType(description, uri)
        return when {
            mimeType?.startsWith("image/") == true -> parseImage(uri, mimeType)
            else -> parseFile(uri, mimeType)
        }
    }

    private fun parseText(item: ClipData.Item): ClipboardEvent? {
        val rawText = try {
            item.coerceToText(null)?.toString()?.trim()
        } catch (e: SecurityException) {
            // Android 10+ may block clipboard access in background
            return null
        } catch (e: Exception) {
            // Other exceptions (e.g., RemoteException) can occur
            return null
        } ?: return null
        if (rawText.isEmpty()) return null
        if (Patterns.WEB_URL.matcher(rawText).matches()) {
            return buildLinkEvent(rawText)
        }
        val bytes = rawText.encodeToByteArray()
        val metadata = mapOf(
            "size" to bytes.size.toString(),
            "hash" to sha256Hex(bytes),
            "encoding" to "UTF-8"
        )
        val preview = rawText.truncate(100)
        return ClipboardEvent(
            id = newEventId(),
            type = ClipboardType.TEXT,
            content = rawText,
            preview = preview,
            metadata = metadata,
            createdAt = Instant.now()
        )
    }

    private fun parseLink(item: ClipData.Item): ClipboardEvent? {
        val text = item.text?.toString()?.trim()
        if (!text.isNullOrEmpty() && Patterns.WEB_URL.matcher(text).matches()) {
            return buildLinkEvent(text)
        }
        val uri = item.uri ?: return null
        if (uri.scheme?.lowercase(Locale.US) in listOf("http", "https")) {
            return buildLinkEvent(uri.toString())
        }
        return null
    }

    private fun parseLinkFromUri(uri: Uri): ClipboardEvent? {
        return buildLinkEvent(uri.toString())
    }

    private fun buildLinkEvent(url: String): ClipboardEvent {
        val bytes = url.encodeToByteArray()
        val metadata = mapOf(
            "size" to bytes.size.toString(),
            "hash" to sha256Hex(bytes),
            "mime_type" to "text/uri-list"
        )
        val preview = url.truncate(100)
        return ClipboardEvent(
            id = newEventId(),
            type = ClipboardType.LINK,
            content = url,
            preview = preview,
            metadata = metadata,
            createdAt = Instant.now()
        )
    }

    private fun parseImage(uri: Uri, mimeType: String?): ClipboardEvent? {
        var bitmap: Bitmap? = null
        return try {
            // Check if URI has changed before reading bytes
            // If same URI, skip immediately without reading bytes
            // Note: ClipboardListener will clear URI tracking for "Hypo Clipboard" label
            // to allow user-initiated copies from history to sync
            if (uri == lastImageUri && lastImageHash != null) {
                android.util.Log.d("ClipboardParser", "⏭️ Clipboard URI unchanged, skipping parse (URI: ${uri.lastPathSegment?.take(30)}...)")
                return null
            }
            
            // Read bytes only if URI changed
            val bytes = readBytes(uri) ?: return null
            
            // Calculate hash from ORIGINAL bytes IMMEDIATELY after reading
            // This ensures stable hash for duplicate detection even if compression varies
            val originalHash = sha256Hex(bytes)
            
            // Check if we've seen this hash before - skip EARLY to avoid expensive processing
            synchronized(hashLock) {
                if (seenImageHashes.contains(originalHash)) {
                    android.util.Log.d("ClipboardParser", "⏭️ Skipping duplicate image (hash match: ${originalHash.take(16)}...) - avoiding expensive parsing")
                    // Update URI tracking even though we're skipping
                    lastImageUri = uri
                    lastImageHash = originalHash
                    return null
                }
                // Keep only last 100 hashes to prevent memory bloat
                if (seenImageHashes.size >= 100) {
                    seenImageHashes.clear()
                }
                seenImageHashes.add(originalHash)
                // Track this URI/hash combination
                lastImageUri = uri
                lastImageHash = originalHash
            }
            
            // Check if image is too large before decoding
            if (bytes.size > SizeConstants.MAX_ATTACHMENT_BYTES * 10) {
                android.util.Log.w("ClipboardParser", "⚠️ Image too large: ${formatBytes(bytes.size.toLong())}, skipping")
                return null
            }
            
            // First, get image dimensions without loading full image into memory
            val options = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            val originalWidth = options.outWidth
            val originalHeight = options.outHeight
            
            if (originalWidth <= 0 || originalHeight <= 0) {
                android.util.Log.w("ClipboardParser", "⚠️ Invalid image dimensions: ${originalWidth}×${originalHeight}")
                return null
            }
            
            // Calculate sample size to avoid OOM
            val sampleSize = calculateInSampleSize(options, 1920, 1920)
            val decodeOptions = BitmapFactory.Options().apply {
                inSampleSize = sampleSize
                inPreferredConfig = Bitmap.Config.RGB_565 // Use less memory
            }
            
            // Decode with sample size
            bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decodeOptions)
                ?: run {
                    android.util.Log.w("ClipboardParser", "⚠️ Failed to decode image")
                    return null
                }
            
            val width = bitmap.width
            val height = bitmap.height

            val format = when {
                mimeType.isNullOrEmpty() -> "jpeg"
                mimeType.contains("png") -> "png"
                mimeType.contains("webp") -> "webp"
                mimeType.contains("gif") -> "gif"
                else -> "jpeg"
            }

            var encodedBytes = encodeBitmap(bitmap, format)
            
            // Compress if larger than target size (accounting for base64 + JSON overhead)
            val maxRawSize = SizeConstants.MAX_RAW_SIZE_FOR_COMPRESSION
            if (encodedBytes.size > maxRawSize) {
                android.util.Log.d("ClipboardParser", "📐 Image too large: ${formatBytes(encodedBytes.size.toLong())}, scaling down...")
                val scaledBitmap = bitmap.scaleToMaxPixels(SizeConstants.MAX_IMAGE_DIMENSION_PX) // Scale to reasonable size
                bitmap.recycle() // Free original bitmap
                bitmap = scaledBitmap
                encodedBytes = encodeBitmap(bitmap, "jpeg", quality = 85)
            }
            
            // Further compression if still too large
            if (encodedBytes.size > maxRawSize) {
                encodedBytes = shrinkUntilSize(bitmap, maxRawSize)
            }

            // Final check - if still too large, show warning and skip
            if (encodedBytes.size > SizeConstants.MAX_ATTACHMENT_BYTES) {
                android.util.Log.w("ClipboardParser", "⚠️ Image exceeds ${SizeConstants.MAX_ATTACHMENT_BYTES / (1024 * 1024)}MB limit: ${formatBytes(encodedBytes.size.toLong())}, skipping")
                onFileTooLarge?.invoke("Image", encodedBytes.size.toLong())
                return null
            }

            val thumbnail = bitmap.scaleToThumbnail(128)
            val metadata = buildMap {
                put("size", encodedBytes.size.toString())
                put("hash", originalHash) // Use hash from original bytes, not compressed
                put("width", width.toString())
                put("height", height.toString())
                put("mime_type", resolvedMimeForFormat(format))
                thumbnail?.let {
                    put("thumbnail_base64", base64Encoder.encodeToString(it))
                }
                
                // Try to get filename if available (e.g. copied from file manager)
                val fileMeta = queryMetadata(uri)
                val name = fileMeta?.displayName ?: uri.lastPathSegment
                if (!name.isNullOrEmpty() && name != "pasted_image" && !name.startsWith("image:")) {
                     put("file_name", name)
                }
            }

            // val base64 = "" // Clear content to avoid memory bloat (Variable not used)
            val extension = resolvedMimeForFormat(format).substringAfter("/", "png")
            val localPath = try {
                storageManager.save(encodedBytes, extension, isImage = true)
            } catch (e: Exception) {
                android.util.Log.e("ClipboardParser", "❌ Failed to save image to disk: ${e.message}")
                null
            }
            
            // If saving failed, localPath is null, so we might want to keep base64 as fallback?
            // But we already set base64 to empty string.
            // If saving fails, we should probably fail the whole operation or fallback to base64.
            // Let's fallback for safety:
            val effectiveContent = if (localPath == null) base64Encoder.encodeToString(encodedBytes) else ""
            
            val preview = "Image ${width}×${height} (${formatBytes(encodedBytes.size.toLong())})"
            ClipboardEvent(
                id = newEventId(),
                type = ClipboardType.IMAGE,
                content = effectiveContent,
                preview = preview,
                metadata = metadata,
                createdAt = Instant.now(),
                localPath = localPath
            )
        } catch (e: OutOfMemoryError) {
            android.util.Log.e("ClipboardParser", "❌ OutOfMemoryError in parseImage: ${e.message}", e)
            null
        } catch (e: SecurityException) {
            android.util.Log.d("ClipboardParser", "🔒 parseImage: Clipboard access blocked: ${e.message}")
            null
        } catch (e: Exception) {
            android.util.Log.e("ClipboardParser", "❌ Error in parseImage: ${e.message}", e)
            null
        } finally {
            // Always recycle bitmap to free memory
            bitmap?.recycle()
        }
    }
    
    private fun calculateInSampleSize(options: BitmapFactory.Options, reqWidth: Int, reqHeight: Int): Int {
        val height = options.outHeight
        val width = options.outWidth
        var inSampleSize = 1

        if (height > reqHeight || width > reqWidth) {
            val halfHeight = height / 2
            val halfWidth = width / 2

            while ((halfHeight / inSampleSize) >= reqHeight && (halfWidth / inSampleSize) >= reqWidth) {
                inSampleSize *= 2
            }
        }
        return inSampleSize
    }

    private fun parseFile(uri: Uri, mimeTypeOverride: String?): ClipboardEvent? {
        return try {
            val metadata = queryMetadata(uri)
            val size = metadata?.size ?: 0L
            val filename = metadata?.displayName ?: uri.lastPathSegment ?: "file"
            
            // Check size before reading
            if (size > SizeConstants.MAX_ATTACHMENT_BYTES) {
                android.util.Log.w("ClipboardParser", "⚠️ File too large: ${formatBytes(size)} (limit: ${formatBytes(SizeConstants.MAX_ATTACHMENT_BYTES.toLong())})")
                onFileTooLarge?.invoke(filename, size)
                return null
            }
            if (size <= 0L) return null
            
            // Stream to disk and calculate hash simultaneously
            var localPath: String? = null
            var hash: String? = null
            
            try {
                // Open input stream
                val inputStream = if (uri.scheme == ContentResolver.SCHEME_FILE) {
                    uri.path?.let { File(it).takeIf { f -> f.exists() }?.inputStream() }
                } else {
                    contentResolver.openInputStream(uri)
                }
                
                inputStream?.use { input ->
                    val digest = MessageDigest.getInstance("SHA-256")
                    val digestStream = java.security.DigestInputStream(input, digest)
                    val extension = filename.substringAfterLast('.', "").lowercase().ifEmpty { "bin" }
                    
                    // Save to storage (consumes stream)
                    localPath = storageManager.save(digestStream, extension, isImage = false)
                    
                    // Get hash after stream is consumed
                    hash = digest.digest().joinToString("") { "%02x".format(it) }
                }
            } catch (e: Exception) {
                android.util.Log.e("ClipboardParser", "❌ Failed to save file stream: ${e.message}", e)
                return null
            }

            if (localPath == null) return null
            
            // Verify size from saved file (optional, but good practice)
            val savedFile = File(localPath!!)
            if (savedFile.length() > SizeConstants.MAX_ATTACHMENT_BYTES) {
                 android.util.Log.w("ClipboardParser", "⚠️ Saved file too large: ${formatBytes(savedFile.length())}, deleting...")
                 savedFile.delete()
                 onFileTooLarge?.invoke(filename, savedFile.length())
                 return null
            }

            val mimeType = mimeTypeOverride ?: metadata?.mimeType ?: "application/octet-stream"
            val meta = mapOf(
                "size" to savedFile.length().toString(),
                "hash" to (hash ?: ""),
                "mime_type" to mimeType,
                "filename" to filename
            )
            val preview = "$filename (${formatBytes(savedFile.length())})"
            
            // Content is empty, we refer to localPath
            return ClipboardEvent(
                id = newEventId(),
                type = ClipboardType.FILE,
                content = "",
                preview = preview,
                metadata = meta,
                createdAt = Instant.now(),
                localPath = localPath
            )
        } catch (e: SecurityException) {
            android.util.Log.d("ClipboardParser", "🔒 parseFile: Clipboard access blocked: ${e.message}")
            null
        } catch (e: Exception) {
            android.util.Log.w("ClipboardParser", "⚠️ Error in parseFile: ${e.message}", e)
            null
        }
    }

    private fun resolveMimeType(description: ClipDescription, uri: Uri): String? {
        val resolverType = runCatching { contentResolver.getType(uri) }.getOrNull()
        if (!resolverType.isNullOrEmpty()) return resolverType

        for (index in 0 until description.mimeTypeCount) {
            val type = description.getMimeType(index)
            if (!type.isNullOrEmpty()) {
                return type
            }
        }

        if (uri.scheme == ContentResolver.SCHEME_FILE) {
            val extension = MimeTypeMap.getFileExtensionFromUrl(uri.toString())
                ?.lowercase(Locale.US)
            if (!extension.isNullOrEmpty()) {
                return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            }
        }
        return null
    }

    private fun readBytes(uri: Uri): ByteArray? {
        return when (uri.scheme) {
            ContentResolver.SCHEME_CONTENT,
            ContentResolver.SCHEME_ANDROID_RESOURCE -> runCatching {
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            }.getOrNull()
            ContentResolver.SCHEME_FILE -> uri.path?.let { path ->
                runCatching { File(path).takeIf(File::exists)?.readBytes() }.getOrNull()
            }
            else -> null
        }
    }

    private fun encodeBitmap(bitmap: Bitmap, format: String, quality: Int = 90): ByteArray {
        val output = ByteArrayOutputStream()
        val compressFormat = when (format.lowercase(Locale.US)) {
            "png" -> Bitmap.CompressFormat.PNG
            "webp" -> Bitmap.CompressFormat.WEBP_LOSSY
            else -> Bitmap.CompressFormat.JPEG
        }
        bitmap.compress(compressFormat, quality, output)
        return output.toByteArray()
    }

    private fun shrinkUntilSize(bitmap: Bitmap, maxBytes: Int): ByteArray {
        var quality = 80
        var current = encodeBitmap(bitmap, "jpeg", quality)
        while (current.size > maxBytes && quality > 40) {
            quality -= 10
            current = encodeBitmap(bitmap, "jpeg", quality)
        }
        return current
    }

    private fun Bitmap.scaleToMaxPixels(maxPixels: Int): Bitmap {
        val largest = max(width, height)
        if (largest <= maxPixels) return this
        val ratio = maxPixels.toFloat() / largest
        val targetWidth = (width * ratio).roundToInt().coerceAtLeast(1)
        val targetHeight = (height * ratio).roundToInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(this, targetWidth, targetHeight, true)
    }

    private fun Bitmap.scaleToThumbnail(maxSize: Int): ByteArray? {
        return try {
            val maxSide = max(width, height)
            val thumbnailBitmap = if (maxSide <= maxSize) this else {
                val ratio = maxSize.toFloat() / maxSide
                val targetWidth = (width * ratio).roundToInt().coerceAtLeast(1)
                val targetHeight = (height * ratio).roundToInt().coerceAtLeast(1)
                Bitmap.createScaledBitmap(this, targetWidth, targetHeight, true)
            }
            val output = ByteArrayOutputStream()
            val success = thumbnailBitmap.compress(Bitmap.CompressFormat.PNG, 90, output)
            // Recycle scaled bitmap if it's different from original
            if (thumbnailBitmap !== this) {
                thumbnailBitmap.recycle()
            }
            if (!success) {
                return null
            }
            output.toByteArray()
        } catch (e: OutOfMemoryError) {
            android.util.Log.e("ClipboardParser", "❌ OutOfMemoryError in scaleToThumbnail: ${e.message}", e)
            null
        } catch (e: Exception) {
            android.util.Log.w("ClipboardParser", "⚠️ Error in scaleToThumbnail: ${e.message}", e)
            null
        }
    }

    private fun resolvedMimeForFormat(format: String): String {
        return when (format.lowercase(Locale.US)) {
            "png" -> "image/png"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            else -> "image/jpeg"
        }
    }

    private fun queryMetadata(uri: Uri): FileMetadata? {
        return when (uri.scheme) {
            ContentResolver.SCHEME_FILE -> uri.path?.let { path ->
                val file = File(path)
                if (!file.exists()) return null
                FileMetadata(
                    displayName = file.name,
                    size = file.length(),
                    mimeType = MimeTypeMap.getSingleton()
                        .getMimeTypeFromExtension(file.extension.lowercase(Locale.US))
                )
            }
            ContentResolver.SCHEME_CONTENT, ContentResolver.SCHEME_ANDROID_RESOURCE -> {
                val projection = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
                contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (cursor.moveToFirst()) {
                        val displayName = if (nameIndex >= 0) cursor.getString(nameIndex) else null
                        val size = if (sizeIndex >= 0) cursor.getLong(sizeIndex) else null
                        FileMetadata(
                            displayName = displayName,
                            size = size,
                            mimeType = runCatching { contentResolver.getType(uri) }.getOrNull()
                        )
                    } else {
                        null
                    }
                }
            }
            else -> null
        }
    }

    private fun formatBytes(size: Long): String {
        if (size < 1024) return "$size B"
        val units = arrayOf("KB", "MB")
        var value = size.toDouble()
        var unitIndex = -1
        while (value >= 1024 && unitIndex < units.lastIndex) {
            value /= 1024
            unitIndex++
        }
        val formatter = DecimalFormat("#.##")
        return formatter.format(value) + " " + units[unitIndex]
    }

    fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString(separator = "") { byte ->
            (byte.toInt() and 0xFF).toString(16).padStart(2, '0')
        }
    }

    private fun String.truncate(length: Int): String {
        return if (this.length <= length) this else this.substring(0, length)
    }

    @VisibleForTesting
    internal fun newEventId(): String = java.util.UUID.randomUUID().toString()

    private data class FileMetadata(
        val displayName: String?,
        val size: Long?,
        val mimeType: String?
    )
}
