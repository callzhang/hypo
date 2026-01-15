package com.hypo.clipboard.crypto

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import androidx.test.core.app.ApplicationProvider
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkConstructor
import io.mockk.mockkStatic
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30]) // Use SDK 30 to support EncryptedSharedPreferences
class SecureKeyStoreTest {

    private lateinit var context: Context
    private lateinit var secureKeyStore: SecureKeyStore

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        
        // Mock Log to avoid pollution
        mockkStatic(android.util.Log::class)
        every { android.util.Log.d(any(), any()) } returns 0
        every { android.util.Log.e(any(), any()) } returns 0

        // Mock EncryptedSharedPreferences to return a standard SharedPreferences
        mockkStatic(EncryptedSharedPreferences::class)
        val standardPrefs = context.getSharedPreferences("test_prefs", Context.MODE_PRIVATE)
        
        every {
            EncryptedSharedPreferences.create(
                any<Context>(),
                any<String>(),
                any<MasterKey>(),
                any<EncryptedSharedPreferences.PrefKeyEncryptionScheme>(),
                any<EncryptedSharedPreferences.PrefValueEncryptionScheme>()
            )
        } returns standardPrefs

        // Mock MasterKey to avoid KeyStore access
        mockkConstructor(MasterKey.Builder::class)
        every { anyConstructed<MasterKey.Builder>().setKeyScheme(any()) } returns try {
            MasterKey.Builder(context) // return self-reference properly if possible, or just a mock
        } catch (e: Exception) {
            // Robolectric might fail instantiating real builder, so return a mock
            mockk<MasterKey.Builder>() 
        }
        
        // Actually, safer to just return a mock for the builder chain
        val mockBuilder = mockk<MasterKey.Builder>(relaxed = true)
        every { anyConstructed<MasterKey.Builder>().setKeyScheme(any()) } returns mockBuilder
        every { mockBuilder.build() } returns mockk<MasterKey>()
        
        // Also catch the constructor call itself if possible? 
        // No, mockkConstructor intercepts the constructor. 
        // But MasterKey.Builder(context) is what is called. 
        
        secureKeyStore = SecureKeyStore(context)
    }

    @After
    fun tearDown() {
        io.mockk.unmockkAll()
    }

    @Test
    fun `saveKey saves encoded key`() = runTest {
        val deviceId = "TestDevice"
        val key = byteArrayOf(1, 2, 3, 4)

        secureKeyStore.saveKey(deviceId, key)

        val loaded = secureKeyStore.loadKey(deviceId)
        assertArrayEquals(key, loaded)
    }

    @Test
    fun `saveKey normalizes deviceId lowercase`() = runTest {
        val deviceIdMixed = "MixedCaseDevice"
        val deviceIdLower = "mixedcasedevice"
        val key = byteArrayOf(5, 6, 7, 8)

        secureKeyStore.saveKey(deviceIdMixed, key)

        // Should be able to retrieve using lowercase ID
        val loaded = secureKeyStore.loadKey(deviceIdLower)
        assertArrayEquals(key, loaded)
    }

    @Test
    fun `loadKey returns null for unknown device`() = runTest {
        val loaded = secureKeyStore.loadKey("unknown-device")
        assertNull(loaded)
    }

    @Test
    fun `deleteKey removes key`() = runTest {
        val deviceId = "device-to-delete"
        val key = byteArrayOf(9, 10)

        secureKeyStore.saveKey(deviceId, key)
        secureKeyStore.deleteKey(deviceId)

        val loaded = secureKeyStore.loadKey(deviceId)
        assertNull(loaded)
    }

    @Test
    fun `deleteKey handles mixed case correctly`() = runTest {
        val deviceId = "DeleteMe"
        val key = byteArrayOf(11, 12)

        secureKeyStore.saveKey(deviceId, key)
        
        // Delete using mixed case (should normalize internally)
        secureKeyStore.deleteKey(deviceId)

        val loaded = secureKeyStore.loadKey(deviceId.lowercase())
        assertNull(loaded)
    }

    @Test
    fun `getAllDeviceIds returns all saved keys`() = runTest {
        val device1 = "device1"
        val device2 = "device2"
        secureKeyStore.saveKey(device1, byteArrayOf(1))
        secureKeyStore.saveKey(device2, byteArrayOf(2))

        val allIds = secureKeyStore.getAllDeviceIds()
        assertEquals(2, allIds.size)
        // Note: getAllDeviceIds returns the normalized keys as stored in prefs
        assert(allIds.contains(device1))
        assert(allIds.contains(device2))
    }
}
