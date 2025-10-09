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

private const val MAX_ATTACHMENT_BYTES = 1_048_576
private val base64Encoder = Base64.getEncoder().withoutPadding()

class ClipboardParser(
    private val contentResolver: ContentResolver
) {

    fun parse(clipData: ClipData): ClipboardEvent? {
        if (clipData.itemCount == 0) return null
        val description = clipData.description
        for (index in 0 until clipData.itemCount) {
            val item = clipData.getItemAt(index)
            parseFromUri(description, item)?.let { return it }
            parseLink(item)?.let { return it }
            parseText(item)?.let { return it }
        }
        return null
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
        val rawText = item.coerceToText(null)?.toString()?.trim() ?: return null
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
        val bytes = readBytes(uri) ?: return null
        var bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
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
        if (encodedBytes.size > MAX_ATTACHMENT_BYTES) {
            bitmap = bitmap.scaleToMaxPixels(1920)
            encodedBytes = encodeBitmap(bitmap, "jpeg", quality = 85)
        }
        if (encodedBytes.size > MAX_ATTACHMENT_BYTES) {
            encodedBytes = shrinkUntilSize(bitmap, MAX_ATTACHMENT_BYTES)
        }

        if (encodedBytes.size > MAX_ATTACHMENT_BYTES) return null

        val thumbnail = bitmap.scaleToThumbnail(128)
        val metadata = buildMap {
            put("size", encodedBytes.size.toString())
            put("hash", sha256Hex(encodedBytes))
            put("width", width.toString())
            put("height", height.toString())
            put("mime_type", resolvedMimeForFormat(format))
            thumbnail?.let {
                put("thumbnail_base64", base64Encoder.encodeToString(it))
            }
        }

        val base64 = base64Encoder.encodeToString(encodedBytes)
        val preview = "Image ${width}×${height} (${formatBytes(encodedBytes.size)})"
        return ClipboardEvent(
            id = newEventId(),
            type = ClipboardType.IMAGE,
            content = base64,
            preview = preview,
            metadata = metadata,
            createdAt = Instant.now()
        )
    }

    private fun parseFile(uri: Uri, mimeTypeOverride: String?): ClipboardEvent? {
        val metadata = queryMetadata(uri)
        val size = metadata?.size ?: 0L
        if (size <= 0L || size > MAX_ATTACHMENT_BYTES) return null
        val bytes = readBytes(uri) ?: return null
        if (bytes.size > MAX_ATTACHMENT_BYTES) return null
        val base64 = base64Encoder.encodeToString(bytes)
        val mimeType = mimeTypeOverride ?: metadata?.mimeType ?: "application/octet-stream"
        val filename = metadata?.displayName ?: uri.lastPathSegment ?: "file"
        val meta = mapOf(
            "size" to bytes.size.toString(),
            "hash" to sha256Hex(bytes),
            "mime_type" to mimeType,
            "filename" to filename
        )
        val preview = "$filename (${formatBytes(bytes.size)})"
        return ClipboardEvent(
            id = newEventId(),
            type = ClipboardType.FILE,
            content = base64,
            preview = preview,
            metadata = meta,
            createdAt = Instant.now()
        )
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
        val maxSide = max(width, height)
        val bitmap = if (maxSide <= maxSize) this else {
            val ratio = maxSize.toFloat() / maxSide
            val targetWidth = (width * ratio).roundToInt().coerceAtLeast(1)
            val targetHeight = (height * ratio).roundToInt().coerceAtLeast(1)
            Bitmap.createScaledBitmap(this, targetWidth, targetHeight, true)
        }
        val output = ByteArrayOutputStream()
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 90, output)) {
            return null
        }
        return output.toByteArray()
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

    private fun formatBytes(size: Int): String {
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

    private fun sha256Hex(bytes: ByteArray): String {
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
