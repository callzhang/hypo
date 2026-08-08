package com.hypo.clipboard.service

import kotlin.test.Test
import kotlin.test.assertEquals

class ClipboardServiceStartPolicyTest {
    @Test
    fun `pre oreo devices use regular service start`() {
        val mode = ClipboardServiceStartPolicy.resolveStartMode(
            sdkInt = 25,
            reason = ClipboardServiceStartReason.APP_LAUNCH
        )

        assertEquals(ClipboardServiceStartMode.START_SERVICE, mode)
    }

    @Test
    fun `oreo and newer devices use foreground service start`() {
        val mode = ClipboardServiceStartPolicy.resolveStartMode(
            sdkInt = 34,
            reason = ClipboardServiceStartReason.APP_LAUNCH
        )

        assertEquals(ClipboardServiceStartMode.START_FOREGROUND_SERVICE, mode)
    }

    @Test
    fun `periodic worker attempts foreground service start so system exemptions can apply`() {
        val mode = ClipboardServiceStartPolicy.resolveStartMode(
            sdkInt = 34,
            reason = ClipboardServiceStartReason.KEEP_ALIVE_WORKER
        )

        assertEquals(ClipboardServiceStartMode.START_FOREGROUND_SERVICE, mode)
    }
}
