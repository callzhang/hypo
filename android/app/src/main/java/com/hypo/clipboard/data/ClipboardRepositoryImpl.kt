package com.hypo.clipboard.data

import com.hypo.clipboard.data.local.ClipboardDao
import com.hypo.clipboard.data.local.ClipboardEntity
import com.hypo.clipboard.domain.model.ClipboardItem
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ClipboardRepositoryImpl @Inject constructor(
    private val dao: ClipboardDao
) : ClipboardRepository {

    override fun observeHistory(limit: Int): Flow<List<ClipboardItem>> =
        dao.observe(limit).map { list -> list.map { it.toDomain() } }

    override suspend fun upsert(item: ClipboardItem) {
        dao.upsert(item.toEntity())
    }

    override suspend fun delete(id: String) {
        dao.deleteById(id)
    }

    override suspend fun clear() {
        dao.clear()
    }

    private fun ClipboardItem.toEntity(): ClipboardEntity = ClipboardEntity(
        id = id.ifEmpty { UUID.randomUUID().toString() },
        type = type,
        content = content,
        preview = preview,
        metadata = metadata,
        deviceId = deviceId,
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
        createdAt = createdAt,
        isPinned = isPinned
    )
}
