package com.hypo.clipboard.data.local

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.io.InputStream
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class StorageManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    companion object {
        private const val TAG = "StorageManager"
        private const val IMAGES_DIR = "images"
        private const val FILES_DIR = "files"
    }

    private val imagesDir: File by lazy {
        File(context.cacheDir, IMAGES_DIR).apply { mkdirs() }
    }

    private val filesDir: File by lazy {
        File(context.cacheDir, FILES_DIR).apply { mkdirs() }
    }

    /**
     * Save byte array to disk.
     * @param data The data to save.
     * @param extension File extension (e.g. "png", "pdf").
     * @param isImage Whether this is an image (determines subdirectory).
     * @return Absolute path to the saved file.
     */
    fun save(data: ByteArray, extension: String, isImage: Boolean = true): String {
        return save(java.io.ByteArrayInputStream(data), extension, isImage)
    }

    fun save(input: java.io.InputStream, extension: String, isImage: Boolean = true): String {
        val dir = if (isImage) imagesDir else filesDir
        val filename = "${UUID.randomUUID()}.$extension"
        val file = File(dir, filename)
        
        try {
            file.outputStream().use { output ->
                input.copyTo(output)
            }
            Log.d(TAG, "✅ Saved stream to ${file.absolutePath}")
            return file.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to save file: ${e.message}", e)
            throw e
        }
    }



    /**
     * Read bytes from file path.
     */
    fun read(path: String): ByteArray? {
        val file = File(path)
        return if (file.exists()) {
            try {
                file.readBytes()
            } catch (e: Exception) {
                Log.e(TAG, "❌ Failed to read file $path: ${e.message}", e)
                null
            }
        } else {
            Log.w(TAG, "⚠️ File not found: $path")
            null
        }
    }
    
    /**
     * Check if file exists.
     */
    fun exists(path: String?): Boolean {
        if (path == null) return false
        return File(path).exists()
    }

    /**
     * Delete file at path.
     */
    fun delete(path: String) {
        val file = File(path)
        if (file.exists()) {
            if (file.delete()) {
                Log.d(TAG, "🗑️ Deleted file: $path")
            } else {
                Log.w(TAG, "⚠️ Failed to delete file: $path")
            }
        }
    }

    /**
     * Clear all managed files.
     */
    fun clearAll() {
        Log.w(TAG, "🧹 Clearing all storage files...")
        try {
            imagesDir.deleteRecursively()
            filesDir.deleteRecursively()
            imagesDir.mkdirs()
            filesDir.mkdirs()
            Log.d(TAG, "✅ Storage cleared")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to clear storage: ${e.message}", e)
        }
    }
}
