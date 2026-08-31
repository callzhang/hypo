package com.hypo.clipboard.ui.settings

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.hypo.clipboard.R
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SettingsCopyTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun `accessibility copy does not promise background clipboard access`() {
        val copy = listOf(
            context.getString(R.string.accessibility_service_description),
            context.getString(R.string.settings_accessibility_service_description),
            context.getString(R.string.settings_accessibility_service_note)
        ).joinToString(" ")

        assertFalse(
            copy.contains("background clipboard", ignoreCase = true),
            "Accessibility copy must not promise Android background clipboard access."
        )
        assertFalse(
            copy.contains("background updates", ignoreCase = true),
            "Accessibility copy must not imply reliable background clipboard updates."
        )
    }

    @Test
    fun `pair button copy points to code pairing since LAN pairing moved into the devices list`() {
        val buttonCopy = context.getString(R.string.pairing_start)
        val titleCopy = context.getString(R.string.pairing_title)

        assertTrue(
            buttonCopy.contains("code", ignoreCase = true),
            "The pairing entry button must advertise code pairing; LAN pairing happens inline in the Devices section."
        )
        assertTrue(
            titleCopy.contains("code", ignoreCase = true),
            "The pairing screen is code-only, so its title must say so."
        )
    }

    @Test
    fun `notification copy does not point to unsupported clipboard permission toggle`() {
        val copy = context.getString(R.string.service_notification_permission_body)

        assertFalse(
            copy.contains("Allow clipboard access", ignoreCase = true),
            "Notification copy must not point users to an unsupported clipboard permission toggle."
        )
    }
}
