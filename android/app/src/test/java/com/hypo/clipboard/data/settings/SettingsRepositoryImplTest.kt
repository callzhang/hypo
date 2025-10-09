package com.hypo.clipboard.data.settings

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.deleteIfExists
import kotlin.io.path.div
import java.util.Comparator
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsRepositoryImplTest {
    private lateinit var tempDir: Path
    private lateinit var repository: SettingsRepositoryImpl
    private lateinit var scope: TestScope

    @BeforeTest
    fun setUp() {
        tempDir = Files.createTempDirectory("settings-repo-test")
        scope = TestScope(StandardTestDispatcher())
        val dataStore = PreferenceDataStoreFactory.createWithPath(
            scope = scope,
            produceFile = { tempDir / "settings.preferences_pb" }
        )
        repository = SettingsRepositoryImpl(dataStore)
    }

    @AfterTest
    fun tearDown() {
        scope.cancel()
        Files.walk(tempDir).use { stream ->
            stream.sorted(Comparator.reverseOrder()).forEach { path ->
                if (path != tempDir) {
                    path.deleteIfExists()
                }
            }
        }
        tempDir.deleteIfExists()
    }

    @Test
    fun `defaults emitted when store is empty`() = runTest {
        val settings = repository.settings.first()
        assertEquals(true, settings.lanSyncEnabled)
        assertEquals(true, settings.cloudSyncEnabled)
        assertEquals(UserSettings.DEFAULT_HISTORY_LIMIT, settings.historyLimit)
        assertEquals(UserSettings.DEFAULT_AUTO_DELETE_DAYS, settings.autoDeleteDays)
    }

    @Test
    fun `setters persist values with clamping`() = runTest {
        repository.setLanSyncEnabled(false)
        repository.setCloudSyncEnabled(false)
        repository.setHistoryLimit(UserSettings.MAX_HISTORY_LIMIT + 100)
        repository.setAutoDeleteDays(UserSettings.MIN_AUTO_DELETE_DAYS - 10)

        val updated = repository.settings.first { settings ->
            !settings.lanSyncEnabled &&
                !settings.cloudSyncEnabled &&
                settings.historyLimit == UserSettings.MAX_HISTORY_LIMIT &&
                settings.autoDeleteDays == UserSettings.MIN_AUTO_DELETE_DAYS
        }

        assertEquals(false, updated.lanSyncEnabled)
        assertEquals(false, updated.cloudSyncEnabled)
        assertEquals(UserSettings.MAX_HISTORY_LIMIT, updated.historyLimit)
        assertEquals(UserSettings.MIN_AUTO_DELETE_DAYS, updated.autoDeleteDays)
    }
}
