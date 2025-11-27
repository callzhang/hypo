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
        return dao.observe().map { list ->
            Log.d("ClipboardRepository", "📋 Flow emitted: ${list.size} items (before limit)")
            list.map { it.toDomain() }
        }
    }

    override suspend fun upsert(item: ClipboardItem) {
        Log.d("ClipboardRepository", "💾 Upserting item: id=${item.id.take(20)}..., type=${item.type}, preview=${item.preview.take(30)}")
        
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
        // Get all entries except the latest one
        val allEntries = dao.observe().firstOrNull() ?: return null
        val latestEntry = allEntries.firstOrNull()
        val historyEntries = if (latestEntry != null) {
            allEntries.filter { it.id != latestEntry.id }
        } else {
            allEntries
        }
        
        // Find matching entry using unified matching logic
        return historyEntries
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
        deviceId = deviceId,
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
        deviceId = deviceId,
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
