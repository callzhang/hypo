package com.hypo.clipboard.data

import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import kotlinx.coroutines.flow.Flow
import java.time.Instant

interface ClipboardRepository {
    fun observeHistory(limit: Int = 200): Flow<List<ClipboardItem>>
    suspend fun upsert(item: ClipboardItem)
    suspend fun delete(id: String)
    suspend fun clear()
    suspend fun getLatestEntry(): ClipboardItem?
    suspend fun findMatchingEntryInHistory(item: ClipboardItem): ClipboardItem?
    suspend fun updateTimestamp(id: String, newTimestamp: Instant)
    // Load full content for an item (needed when copying IMAGE/FILE items that have empty content in list view)
    suspend fun loadFullContent(itemId: String): String?
}
