package com.hypo.clipboard.di

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import java.nio.file.Files

class AppModuleTest {
    @Test
    fun `computeWsAuthToken returns null when secret blank`() {
        val module = AppModule
        val token = module.computeWsAuthToken("", "device-id")
        assertNull(token)
    }

    @Test
    fun `computeWsAuthToken returns token when secret present`() {
        val module = AppModule
        val token = module.computeWsAuthToken("test-secret", "device-id")
        assertTrue(token?.isNotBlank() == true)
    }

    @Test
    fun `computeWsAuthToken matches deterministic output`() {
        val module = AppModule
        val token1 = module.computeWsAuthToken("test-secret", "device-id")
        val token2 = module.computeWsAuthToken("test-secret", "device-id")
        assertEquals(token1, token2)
    }

    @Test
    fun `resolveRelayAuthSecret prefers app private file`() {
        val filesDir = Files.createTempDirectory("hypo-auth").toFile()
        try {
            filesDir.resolve("relay_ws_auth_token").writeText(" private-secret\n")

            val secret = AppModule.resolveRelayAuthSecret(filesDir, "build-secret")

            assertEquals("private-secret", secret)
        } finally {
            filesDir.deleteRecursively()
        }
    }

    @Test
    fun `resolveRelayAuthSecret falls back when private file missing`() {
        val filesDir = Files.createTempDirectory("hypo-auth").toFile()
        try {
            val secret = AppModule.resolveRelayAuthSecret(filesDir, " build-secret ")

            assertEquals("build-secret", secret)
        } finally {
            filesDir.deleteRecursively()
        }
    }
}
