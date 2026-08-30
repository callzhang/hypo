package com.hypo.clipboard.ui.history

import java.io.File
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class HistoryScreenLayoutTest {
    private val projectDirectory = File(requireNotNull(System.getProperty("hypo.android.project.dir")))

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
        assertEquals(40, historySearchBarHeightDp)
        assertEquals(240, historySearchBarMaxWidthDp)
        assertEquals(true, historySearchFieldSingleLine)
        assertEquals(false, historyShowsTitle)
    }

    @Test
    fun `history list draws behind navigation bar with safe end content padding`() {
        val source = File(
            projectDirectory,
            "src/main/java/com/hypo/clipboard/ui/history/HistoryScreen.kt"
        ).readText()

        assertContains(source, "val navigationBarBottomPadding = WindowInsets.navigationBars")
        assertContains(source, ".padding(horizontal = 16.dp)")
        assertContains(source, ".padding(top = 16.dp)")
        assertContains(
            source,
            "contentPadding = PaddingValues(bottom = navigationBarBottomPadding + 16.dp)"
        )
        assertFalse(source.contains(".fillMaxSize()\n            .padding(16.dp)"))
    }
}
