package com.hypo.clipboard.fakes

import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import java.time.Instant
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

class FakeClipboardRepository(initialItems: List<ClipboardItem> = emptyList()) : ClipboardRepository {
    private val historyFlow = MutableStateFlow(initialItems)
    var clearCallCount: Int = 0
        private set
    private val fullContents = mutableMapOf<String, String>()

    override fun observeHistory(limit: Int): Flow<List<ClipboardItem>> = historyFlow.asStateFlow()

    override suspend fun upsert(item: ClipboardItem) {
        val existing = historyFlow.value.filterNot { it.id == item.id }
        historyFlow.value = listOf(item) + existing
    }

    override suspend fun delete(id: String) {
        historyFlow.value = historyFlow.value.filterNot { it.id == id }
    }

    override suspend fun clear() {
        clearCallCount += 1
        historyFlow.value = emptyList()
    }

    override suspend fun getLatestEntry(): ClipboardItem? = historyFlow.value.firstOrNull()

    override suspend fun findMatchingEntryInHistory(item: ClipboardItem): ClipboardItem? {
        return historyFlow.value.firstOrNull { it.content == item.content && it.type == item.type }
    }

    override suspend fun updateTimestamp(id: String, newTimestamp: Instant) {
        historyFlow.value = historyFlow.value.map { existing ->
            if (existing.id == id) existing.copy(createdAt = newTimestamp) else existing
        }
    }

    override suspend fun loadFullContent(itemId: String): String? {
        return fullContents[itemId] ?: historyFlow.value.firstOrNull { it.id == itemId }?.content
    }

    fun setHistory(items: List<ClipboardItem>) {
        historyFlow.value = items
    }

    fun setFullContent(itemId: String, content: String) {
        fullContents[itemId] = content
    }
}
