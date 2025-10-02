package com.hypo.clipboard.data

import com.hypo.clipboard.domain.model.ClipboardItem
import kotlinx.coroutines.flow.Flow

interface ClipboardRepository {
    fun observeHistory(limit: Int = 200): Flow<List<ClipboardItem>>
    suspend fun upsert(item: ClipboardItem)
    suspend fun delete(id: String)
    suspend fun clear()
}
