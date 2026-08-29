package com.hypo.clipboard.ui.history

import kotlin.test.Test
import kotlin.test.assertEquals

class HistoryScreenLayoutTest {
    @Test
    fun `history top bar keeps search connection icon and settings icon in that order`() {
        assertEquals(
            listOf(
                HistoryTopBarAction.SEARCH,
                HistoryTopBarAction.CONNECTION_STATUS,
                HistoryTopBarAction.SETTINGS
            ),
            historyTopBarActions()
        )
    }

    @Test
    fun `history top bar is compact and has no title`() {
        assertEquals(48, historySearchBarHeightDp)
        assertEquals(false, historyShowsTitle)
    }
}
