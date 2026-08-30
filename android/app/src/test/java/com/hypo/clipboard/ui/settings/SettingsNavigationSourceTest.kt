package com.hypo.clipboard.ui.settings

import java.io.File
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertTrue

class SettingsNavigationSourceTest {
    private val projectDirectory = File(requireNotNull(System.getProperty("hypo.android.project.dir")))

    @Test
    fun `settings top app bar exposes a visible back action`() {
        val source = File(
            projectDirectory,
            "src/main/java/com/hypo/clipboard/ui/settings/SettingsScreen.kt"
        ).readText()

        assertContains(source, "onBack: () -> Unit")
        assertContains(source, "navigationIcon")
        assertContains(source, "Icons.AutoMirrored.Filled.ArrowBack")
    }

    @Test
    fun `settings back action pops the navigation stack`() {
        val source = File(
            projectDirectory,
            "src/main/java/com/hypo/clipboard/MainActivity.kt"
        ).readText()
        val settingsRouteStart = source.indexOf("composable(SETTINGS_ROUTE)")
        val pairingRouteStart = source.indexOf("composable(\"pairing\")")

        assertTrue(settingsRouteStart >= 0, "Settings route must exist")
        assertTrue(pairingRouteStart > settingsRouteStart, "Pairing route must follow Settings")

        val settingsRoute = source.substring(settingsRouteStart, pairingRouteStart)
        assertContains(settingsRoute, "onBack = { navController.popBackStack() }")
    }
}
