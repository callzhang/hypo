package com.hypo.clipboard.data

import com.hypo.clipboard.data.local.ClipboardDao
import com.hypo.clipboard.data.local.ClipboardEntity
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.map
import android.util.Log
import java.time.Instant
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ClipboardRepositoryImpl @Inject constructor(
    private val dao: ClipboardDao
) : ClipboardRepository {

    override fun observeHistory(limit: Int): Flow<List<ClipboardItem>> {
        Log.d("ClipboardRepository", "📋 observeHistory called with limit=$limit")
        // Use observe() without LIMIT to ensure Room Flow emits on all changes
        // Filtering will be done in ViewModel
        // Note: Content is excluded for IMAGE/FILE types to avoid CursorWindow overflow
        // Content will be loaded on-demand when copying or viewing details
        return dao.observe().map { list ->
            Log.d("ClipboardRepository", "📋 Flow emitted: ${list.size} items (before limit)")
            list.map { it.toDomain() }
        }
    }
    
    // Load full content for an item (needed when copying IMAGE/FILE items)
    // For large IMAGE/FILE items, load content separately to avoid CursorWindow overflow
    override suspend fun loadFullContent(itemId: String): String? {
        return try {
            // First try to get the item to check its type
            val item = dao.findByIdWithoutContent(itemId)
            if (item == null) {
                return null
            }
            
            // For IMAGE/FILE types, load content separately to avoid CursorWindow overflow
            if (item.type == ClipboardType.IMAGE || item.type == ClipboardType.FILE) {
                dao.findContentById(itemId)
            } else {
                // For TEXT/LINK, content is already loaded (small)
                item.content
            }
        } catch (e: android.database.sqlite.SQLiteBlobTooBigException) {
            Log.e("ClipboardRepository", "❌ SQLiteBlobTooBigException when loading content for $itemId: ${e.message}", e)
            // Try to load content separately as fallback
            try {
                dao.findContentById(itemId)
            } catch (e2: Exception) {
                Log.e("ClipboardRepository", "❌ Failed to load content separately: ${e2.message}", e2)
                null
            }
        } catch (e: Exception) {
            Log.e("ClipboardRepository", "❌ Error loading full content: ${e.message}", e)
            null
        }
    }

    override suspend fun upsert(item: ClipboardItem) {
        try {
            Log.d("ClipboardRepository", "💾 Upserting item: id=${item.id.take(20)}..., type=${item.type}, preview=${item.preview.take(30)}")
            
            // Check content size for IMAGE/FILE types to prevent crashes
            if ((item.type == ClipboardType.IMAGE || item.type == ClipboardType.FILE) && item.content.length > 20 * 1024 * 1024) {
                // Content is too large (>20MB base64), log warning but still try to save
                Log.w("ClipboardRepository", "⚠️ Large content detected: ${item.content.length} bytes (${item.type}), may cause issues")
            }
            
            // Only update created_at to current time for local items (transportOrigin == null)
            // Preserve original timestamp for received items (transportOrigin != null) to maintain chronological order
            val entity = if (item.transportOrigin == null) {
                // Local item - move to top by updating timestamp
                val now = Instant.now()
                item.toEntity().copy(createdAt = now)
            } else {
                // Received item - preserve original timestamp
                item.toEntity()
            }
            dao.upsert(entity)
            
            if (item.transportOrigin == null) {
                Log.d("ClipboardRepository", "✅ Local item upserted to database (moved to top)")
            } else {
                Log.d("ClipboardRepository", "✅ Received item upserted to database (preserved timestamp: ${item.createdAt})")
            }
        } catch (e: android.database.sqlite.SQLiteBlobTooBigException) {
            Log.e("ClipboardRepository", "❌ SQLiteBlobTooBigException when upserting ${item.type} item: ${e.message}", e)
            // Re-throw to let caller handle it
            throw e
        } catch (e: Exception) {
            Log.e("ClipboardRepository", "❌ Error upserting item: ${e.message}", e)
            // Re-throw to let caller handle it
            throw e
        }
    }

    override suspend fun delete(id: String) {
        dao.deleteById(id)
    }

    override suspend fun clear() {
        dao.clear()
    }
    
    override suspend fun getLatestEntry(): ClipboardItem? {
        return dao.getLatestEntry()?.toDomain()
    }
    
    override suspend fun findMatchingEntryInHistory(item: ClipboardItem): ClipboardItem? {
        // For IMAGE and FILE types, use hash-based matching to avoid loading large content
        // For TEXT and LINK, use content-based matching
        if (item.type == ClipboardType.IMAGE || item.type == ClipboardType.FILE) {
            val hash = item.metadata?.get("hash")
            if (hash != null) {
                // Use hash-based search - find entries with matching hash and type
                // This avoids loading large content into memory
                val allEntries = dao.observe().firstOrNull() ?: return null
                val latestEntry = allEntries.firstOrNull()
                val historyEntries = if (latestEntry != null) {
                    allEntries.filter { it.id != latestEntry.id }
                } else {
                    allEntries
                }
                
                // Find matching entry by hash (more efficient than content comparison)
                return historyEntries
                    .map { it.toDomain() }
                    .firstOrNull { existingItem ->
                        existingItem.type == item.type &&
                        existingItem.metadata?.get("hash") == hash
                    }
            }
        }
        
        // For TEXT/LINK or if hash not available, use content-based matching
        // But limit to recent entries to avoid loading too much data
        val allEntries = dao.observe().firstOrNull() ?: return null
        val latestEntry = allEntries.firstOrNull()
        val historyEntries = if (latestEntry != null) {
            allEntries.filter { it.id != latestEntry.id }
        } else {
            allEntries
        }
        
        // Limit to first 50 entries for performance (most recent matches are more likely)
        return historyEntries
            .take(50)
            .map { it.toDomain() }
            .firstOrNull { existingItem ->
                item.matchesContent(existingItem)
            }
    }
    
    override suspend fun updateTimestamp(id: String, newTimestamp: Instant) {
        dao.updateTimestamp(id, newTimestamp)
    }

    private fun ClipboardItem.toEntity(): ClipboardEntity = ClipboardEntity(
        id = id.ifEmpty { UUID.randomUUID().toString() },
        type = type,
        content = content,
        preview = preview,
        metadata = metadata,
        deviceId = deviceId.lowercase(),  // Normalize to lowercase for consistent matching
        deviceName = deviceName,
        createdAt = createdAt,
        isPinned = isPinned,
        isEncrypted = isEncrypted,
        transportOrigin = transportOrigin?.name
    )

    private fun ClipboardEntity.toDomain(): ClipboardItem = ClipboardItem(
        id = id,
        type = type,
        content = content,
        preview = preview,
        metadata = metadata,
        deviceId = deviceId.lowercase(),  // Normalize to lowercase for consistent matching
        deviceName = deviceName,
        createdAt = createdAt,
        isPinned = isPinned,
        isEncrypted = isEncrypted,
        transportOrigin = transportOrigin?.let { 
            try {
                com.hypo.clipboard.domain.model.TransportOrigin.valueOf(it)
            } catch (e: IllegalArgumentException) {
                null
            }
        }
    )
}
