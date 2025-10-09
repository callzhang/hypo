package com.hypo.clipboard.fakes

import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.domain.model.ClipboardItem
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

class FakeClipboardRepository(initialItems: List<ClipboardItem> = emptyList()) : ClipboardRepository {
    private val historyFlow = MutableStateFlow(initialItems)
    var clearCallCount: Int = 0
        private set

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

    fun setHistory(items: List<ClipboardItem>) {
        historyFlow.value = items
    }
}
