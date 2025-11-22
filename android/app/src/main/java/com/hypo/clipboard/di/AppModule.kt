package com.hypo.clipboard.di

import android.content.Context
import android.net.nsd.NsdManager
import android.net.wifi.WifiManager
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStoreFile
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.room.Room
import com.hypo.clipboard.BuildConfig
import com.hypo.clipboard.crypto.CryptoService
import com.hypo.clipboard.crypto.NonceGenerator
import com.hypo.clipboard.crypto.SecureKeyStore
import com.hypo.clipboard.crypto.SecureRandomNonceGenerator
import com.hypo.clipboard.data.ClipboardRepository
import com.hypo.clipboard.data.ClipboardRepositoryImpl
import com.hypo.clipboard.data.local.ClipboardDao
import com.hypo.clipboard.data.local.HypoDatabase
import com.hypo.clipboard.data.settings.SettingsRepository
import com.hypo.clipboard.data.settings.SettingsRepositoryImpl
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.DeviceKeyStore
import com.hypo.clipboard.sync.NoopSyncTransport
import com.hypo.clipboard.sync.SyncTransport
import com.hypo.clipboard.transport.InMemoryTransportAnalytics
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.TransportAnalytics
import com.hypo.clipboard.transport.lan.LanDiscoveryRepository
import com.hypo.clipboard.transport.lan.LanDiscoverySource
import com.hypo.clipboard.transport.lan.LanRegistrationController
import com.hypo.clipboard.transport.lan.LanRegistrationManager
import com.hypo.clipboard.transport.ws.LanWebSocketClient
import com.hypo.clipboard.transport.ws.OkHttpWebSocketConnector
import com.hypo.clipboard.transport.ws.RelayWebSocketClient
import com.hypo.clipboard.transport.ws.TlsWebSocketConfig
import com.hypo.clipboard.transport.ws.TransportFrameCodec
import com.hypo.clipboard.transport.ws.WebSocketConnector
import okhttp3.OkHttpClient
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import java.time.Clock
import javax.inject.Named
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.json.Json

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): HypoDatabase =
        Room.databaseBuilder(context, HypoDatabase::class.java, "hypo.db")
            .fallbackToDestructiveMigration()
            .build()

    @Provides
    fun provideClipboardDao(database: HypoDatabase): ClipboardDao = database.clipboardDao()

    @Provides
    @Singleton
    fun provideRepository(dao: ClipboardDao): ClipboardRepository = ClipboardRepositoryImpl(dao)

    @Provides
    @Singleton
    fun provideDataStore(
        @ApplicationContext context: Context
    ): DataStore<Preferences> = PreferenceDataStoreFactory.create(
        produceFile = { context.preferencesDataStoreFile("hypo_settings") }
    )

    @Provides
    @Singleton
    fun provideSettingsRepository(
        dataStore: DataStore<Preferences>
    ): SettingsRepository = SettingsRepositoryImpl(dataStore)

    @Provides
    @Singleton
    fun provideNonceGenerator(): NonceGenerator = SecureRandomNonceGenerator()

    @Provides
    @Singleton
    fun provideCryptoService(nonceGenerator: NonceGenerator): CryptoService =
        CryptoService(nonceGenerator)

    @Provides
    @Singleton
    fun provideJson(): Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Provides
    @Singleton
    fun provideClock(): Clock = Clock.systemUTC()

    @Provides
    @Singleton
    fun provideOkHttpClient(): OkHttpClient = OkHttpClient.Builder().build()

    @Provides
    @Singleton
    fun provideSecureKeyStore(@ApplicationContext context: Context): DeviceKeyStore =
        SecureKeyStore(context)

    @Provides
    @Singleton
    fun provideDeviceIdentity(@ApplicationContext context: Context): DeviceIdentity =
        DeviceIdentity(context)

    @Provides
    @Singleton
    @Named("lan_ws_config")
    fun provideLanTlsWebSocketConfig(
        deviceIdentity: DeviceIdentity
    ): TlsWebSocketConfig =
        TlsWebSocketConfig(
            url = "wss://127.0.0.1:${TransportManager.DEFAULT_PORT}/ws",
            fingerprintSha256 = null,
            headers = mapOf(
                "X-Device-Id" to deviceIdentity.deviceId,
                "X-Device-Platform" to "android"
            )
        )

    @Provides
    @Singleton
    @Named("lan_ws_connector")
    fun provideLanWebSocketConnector(
        @Named("lan_ws_config") config: TlsWebSocketConfig
    ): WebSocketConnector =
        OkHttpWebSocketConnector(config)

    @Provides
    @Singleton
    @Named("cloud_ws_config")
    fun provideCloudTlsWebSocketConfig(
        deviceIdentity: DeviceIdentity
    ): TlsWebSocketConfig =
        TlsWebSocketConfig(
            url = BuildConfig.RELAY_WS_URL,
            fingerprintSha256 = BuildConfig.RELAY_CERT_FINGERPRINT.takeIf { it.isNotBlank() },
            headers = mapOf(
                "X-Hypo-Client" to BuildConfig.VERSION_NAME,
                "X-Hypo-Environment" to BuildConfig.RELAY_ENVIRONMENT,
                "X-Device-Id" to deviceIdentity.deviceId,
                "X-Device-Platform" to "android"
            ),
            environment = "cloud"
        )

    @Provides
    @Singleton
    @Named("cloud_ws_connector")
    fun provideCloudWebSocketConnector(
        @Named("cloud_ws_config") config: TlsWebSocketConfig
    ): WebSocketConnector =
        OkHttpWebSocketConnector(config)

    @Provides
    @Singleton
    fun provideTransportFrameCodec(): TransportFrameCodec = TransportFrameCodec()

    @Provides
    @Singleton
    fun provideLanWebSocketClient(
        @Named("lan_ws_config") config: TlsWebSocketConfig,
        @Named("lan_ws_connector") connector: WebSocketConnector,
        frameCodec: TransportFrameCodec,
        analytics: TransportAnalytics,
        transportManager: com.hypo.clipboard.transport.TransportManager
    ): com.hypo.clipboard.transport.ws.LanWebSocketClient = com.hypo.clipboard.transport.ws.LanWebSocketClient(
        config,
        connector,
        frameCodec,
        CoroutineScope(SupervisorJob() + Dispatchers.IO),
        Clock.systemUTC(),
        analytics = analytics,
        transportManager = transportManager
    )
    
    @Provides
    @Singleton
    fun provideSyncTransport(
        lanWebSocketClient: com.hypo.clipboard.transport.ws.LanWebSocketClient,
        relayWebSocketClient: RelayWebSocketClient,
        transportManager: com.hypo.clipboard.transport.TransportManager
    ): SyncTransport = com.hypo.clipboard.transport.ws.FallbackSyncTransport(
        lanTransport = lanWebSocketClient,
        cloudTransport = relayWebSocketClient,
        transportManager = transportManager
    )

    @Provides
    @Singleton
    fun provideRelayWebSocketClient(
        @Named("cloud_ws_config") config: TlsWebSocketConfig,
        @Named("cloud_ws_connector") connector: WebSocketConnector,
        frameCodec: TransportFrameCodec,
        analytics: TransportAnalytics
    ): RelayWebSocketClient = RelayWebSocketClient(
        config = config,
        connector = connector,
        frameCodec = frameCodec,
        analytics = analytics
    )

    @Provides
    fun provideNsdManager(@ApplicationContext context: Context): NsdManager =
        context.getSystemService(Context.NSD_SERVICE) as NsdManager

    @Provides
    fun provideWifiManager(@ApplicationContext context: Context): WifiManager =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    @Provides
    @Singleton
    fun provideLanDiscoveryRepository(
        @ApplicationContext context: Context,
        nsdManager: NsdManager,
        wifiManager: WifiManager
    ): LanDiscoveryRepository = LanDiscoveryRepository(context, nsdManager, wifiManager)

    @Provides
    fun provideLanDiscoverySource(repository: LanDiscoveryRepository): LanDiscoverySource = repository

    @Provides
    @Singleton
    fun provideLanRegistrationManager(
        @ApplicationContext context: Context,
        nsdManager: NsdManager,
        wifiManager: WifiManager
    ): LanRegistrationManager = LanRegistrationManager(context, nsdManager, wifiManager)

    @Provides
    fun provideLanRegistrationController(manager: LanRegistrationManager): LanRegistrationController = manager

    @Provides
    @Singleton
    fun provideTransportAnalytics(): TransportAnalytics = InMemoryTransportAnalytics()

    @Provides
    @Singleton
    fun provideTransportManager(
        @ApplicationContext context: Context,
        discoverySource: LanDiscoverySource,
        registrationController: LanRegistrationController,
        analytics: TransportAnalytics
    ): TransportManager = TransportManager(discoverySource, registrationController, context = context, analytics = analytics)
}
