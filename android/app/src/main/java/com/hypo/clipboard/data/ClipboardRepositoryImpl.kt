package com.hypo.clipboard.data

import com.hypo.clipboard.data.local.ClipboardDao
import com.hypo.clipboard.data.local.ClipboardEntity
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import android.util.Log
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
        dao.upsert(item.toEntity())
        Log.d("ClipboardRepository", "✅ Item upserted to database")
    }

    override suspend fun delete(id: String) {
        dao.deleteById(id)
    }

    override suspend fun clear() {
        dao.clear()
    }
    
    override suspend fun hasRecentDuplicate(content: String, type: ClipboardType, deviceId: String, withinSeconds: Long): Boolean {
        val since = java.time.Instant.now().minusSeconds(withinSeconds)
        val count = dao.countRecentDuplicates(content, type.name, deviceId, since)
        return count > 0
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
        isPinned = isPinned
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
        isPinned = isPinned
    )
}
