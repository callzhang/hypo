package com.hypo.clipboard.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStoreFile
import androidx.test.core.app.ApplicationProvider
// import androidx.test.ext.junit.runners.AndroidJUnit4 hiding this to avoid unresolved reference
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.util.UUID

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SettingsRepositoryTest {

    private lateinit var dataStore: DataStore<Preferences>
    private lateinit var repository: SettingsRepositoryImpl
    private val testDispatcher = UnconfinedTestDispatcher()
    private val testScope = TestScope(testDispatcher)

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        // Create a unique file for each test
        val file = File(context.filesDir, "datastore/settings_test_${UUID.randomUUID()}.preferences_pb")
        
        dataStore = PreferenceDataStoreFactory.create(
            scope = testScope,
            produceFile = { file }
        )
        
        repository = SettingsRepositoryImpl(dataStore)
    }

    @Test
    fun `defaults are correct`() = runTest {
        val settings = repository.settings.first()
        assertTrue(settings.lanSyncEnabled)
        assertTrue(settings.cloudSyncEnabled)
        assertEquals(UserSettings.DEFAULT_HISTORY_LIMIT, settings.historyLimit)
        assertFalse(settings.plainTextModeEnabled)
    }

    @Test
    fun `setLanSyncEnabled updates flow`() = runTest {
        repository.setLanSyncEnabled(false)
        val settings = repository.settings.first()
        assertFalse(settings.lanSyncEnabled)
        
        repository.setLanSyncEnabled(true)
        val settingsUpdated = repository.settings.first()
        assertTrue(settingsUpdated.lanSyncEnabled)
    }

    @Test
    fun `setCloudSyncEnabled updates flow`() = runTest {
        repository.setCloudSyncEnabled(false)
        val settings = repository.settings.first()
        assertFalse(settings.cloudSyncEnabled)
    }

    @Test
    fun `setHistoryLimit updates flow`() = runTest {
        val newLimit = 50
        repository.setHistoryLimit(newLimit)
        val settings = repository.settings.first()
        assertEquals(newLimit, settings.historyLimit)
    }

    @Test
    fun `setHistoryLimit clamps values`() = runTest {
        // Too low
        repository.setHistoryLimit(UserSettings.MIN_HISTORY_LIMIT - 10)
        assertEquals(UserSettings.MIN_HISTORY_LIMIT, repository.settings.first().historyLimit)

        // Too high
        repository.setHistoryLimit(UserSettings.MAX_HISTORY_LIMIT + 100)
        assertEquals(UserSettings.MAX_HISTORY_LIMIT, repository.settings.first().historyLimit)
    }

    @Test
    fun `setPlainTextModeEnabled updates flow`() = runTest {
        repository.setPlainTextModeEnabled(true)
        assertTrue(repository.settings.first().plainTextModeEnabled)
    }
}
