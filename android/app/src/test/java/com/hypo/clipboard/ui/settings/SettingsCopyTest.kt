package com.hypo.clipboard.ui.settings

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.hypo.clipboard.R
import kotlin.test.Test
import kotlin.test.assertFalse
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
    fun `notification copy does not point to unsupported clipboard permission toggle`() {
        val copy = context.getString(R.string.service_notification_permission_body)

        assertFalse(
            copy.contains("Allow clipboard access", ignoreCase = true),
            "Notification copy must not point users to an unsupported clipboard permission toggle."
        )
    }
}
