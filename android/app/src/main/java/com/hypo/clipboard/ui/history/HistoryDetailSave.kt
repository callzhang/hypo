package com.hypo.clipboard.ui.history

import com.hypo.clipboard.domain.model.ClipboardItem
import java.util.Locale

internal fun resolveImageSaveMimeType(item: ClipboardItem): String {
    val explicitMimeType = item.metadata?.get("mime_type")?.trim()
    if (!explicitMimeType.isNullOrEmpty() && explicitMimeType.lowercase(Locale.US).startsWith("image/")) {
        return explicitMimeType
    }

    val format = item.metadata?.get("format")?.trim()?.lowercase(Locale.US)
    return when (format) {
        "jpg", "jpeg" -> "image/jpeg"
        "webp" -> "image/webp"
        "gif" -> "image/gif"
        "heic" -> "image/heic"
        "heif" -> "image/heif"
        "png", null, "" -> "image/png"
        else -> {
            if (format.startsWith("image/")) {
                format
            } else {
                "image/png"
            }
        }
    }
}

internal fun resolveImageSaveFileName(item: ClipboardItem): String {
    val mimeType = resolveImageSaveMimeType(item)
    val metadataFileName = item.metadata?.get("file_name") ?: item.metadata?.get("filename")
    val sanitizedFileName = metadataFileName?.let(::sanitizeImageSaveFileName)

    if (!sanitizedFileName.isNullOrBlank()) {
        return ensureImageFileExtension(sanitizedFileName, mimeType)
    }

    val stableId = item.id.take(8).ifBlank { "clipboard" }
    return "hypo-image-$stableId.${extensionForImageMimeType(mimeType)}"
}

private fun sanitizeImageSaveFileName(fileName: String): String {
    val trimmedFileName = fileName.trim()
    if (trimmedFileName.isEmpty()) {
        return ""
    }

    val invalidChars = setOf('/', '\\', ':', '*', '?', '"', '<', '>', '|')
    val sanitized = buildString(trimmedFileName.length) {
        for (char in trimmedFileName) {
            append(if (char.code < 32 || char in invalidChars) '_' else char)
        }
    }

    return when (sanitized) {
        ".", ".." -> ""
        else -> sanitized
    }
}

private fun ensureImageFileExtension(fileName: String, mimeType: String): String {
    val lastDotIndex = fileName.lastIndexOf('.')
    if (lastDotIndex > 0 && lastDotIndex < fileName.lastIndex) {
        return fileName
    }

    return "$fileName.${extensionForImageMimeType(mimeType)}"
}

private fun extensionForImageMimeType(mimeType: String): String {
    return when (mimeType.lowercase(Locale.US)) {
        "image/jpeg" -> "jpg"
        "image/webp" -> "webp"
        "image/gif" -> "gif"
        "image/heic" -> "heic"
        "image/heif" -> "heif"
        else -> "png"
    }
}
