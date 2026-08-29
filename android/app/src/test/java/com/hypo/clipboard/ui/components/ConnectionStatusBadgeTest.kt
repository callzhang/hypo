package com.hypo.clipboard.ui.components

import androidx.compose.ui.graphics.Color
import com.hypo.clipboard.transport.ConnectionState
import kotlin.test.Test
import kotlin.test.assertEquals

class ConnectionStatusBadgeTest {
    @Test
    fun `cloud icon uses visible top bar tint`() {
        val defaultTint = Color.White
        val cloudTint = Color(0xFF0061A4)

        assertEquals(
            cloudTint,
            connectionStatusIconTint(
                connectionState = ConnectionState.ConnectedCloud,
                defaultTint = defaultTint,
                cloudTint = cloudTint
            )
        )
    }

    @Test
    fun `non-cloud icon keeps its state tint`() {
        val defaultTint = Color(0xFF333333)
        val cloudTint = Color(0xFF0061A4)

        assertEquals(
            defaultTint,
            connectionStatusIconTint(
                connectionState = ConnectionState.ConnectedLan,
                defaultTint = defaultTint,
                cloudTint = cloudTint
            )
        )
    }
}
