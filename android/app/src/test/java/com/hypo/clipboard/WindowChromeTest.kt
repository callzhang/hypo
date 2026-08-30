package com.hypo.clipboard

import android.app.Activity
import android.graphics.Color
import android.view.View
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29])
class WindowChromeTest {
    @Test
    fun `history background draws behind the transparent navigation bar`() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()

        configureEdgeToEdgeWindow(activity.window)

        val edgeToEdgeFlags =
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        assertEquals(Color.TRANSPARENT, activity.window.navigationBarColor)
        assertEquals(Color.TRANSPARENT, activity.window.navigationBarDividerColor)
        assertFalse(activity.window.isNavigationBarContrastEnforced)
        assertTrue(activity.window.decorView.systemUiVisibility and edgeToEdgeFlags == edgeToEdgeFlags)
    }

    @Test
    fun `theme does not draw a navigation bar divider before compose starts`() {
        val projectDirectory = File(requireNotNull(System.getProperty("hypo.android.project.dir")))
        val themesFile = File(projectDirectory, "src/main/res/values/themes.xml")
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(themesFile)
        val items = document.getElementsByTagName("item")
        val themeItems = buildMap {
            repeat(items.length) { index ->
                val item = items.item(index)
                put(item.attributes.getNamedItem("name").nodeValue, item.textContent.trim())
            }
        }

        assertEquals(
            "@android:color/transparent",
            themeItems["android:navigationBarDividerColor"]
        )
    }

    @Test
    fun `root scaffold leaves the bottom navigation inset to each screen`() {
        val projectDirectory = File(requireNotNull(System.getProperty("hypo.android.project.dir")))
        val source = File(
            projectDirectory,
            "src/main/java/com/hypo/clipboard/MainActivity.kt"
        ).readText()
        val rootScaffold = source.substringAfter("Scaffold(").substringBefore(") { innerPadding ->")

        assertContains(rootScaffold, "WindowInsets.safeDrawing.only(")
        assertContains(rootScaffold, "WindowInsetsSides.Top")
        assertContains(rootScaffold, "WindowInsetsSides.Horizontal")
        assertFalse(rootScaffold.contains("WindowInsetsSides.Bottom"))
    }
}
