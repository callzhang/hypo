package com.hypo.clipboard.di

import android.content.Context
import android.net.nsd.NsdManager
import android.net.wifi.WifiManager
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
import com.hypo.clipboard.sync.DeviceIdentity
import com.hypo.clipboard.sync.DeviceKeyStore
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

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): HypoDatabase =
        Room.databaseBuilder(context, HypoDatabase::class.java, "hypo.db").build()

    @Provides
    fun provideClipboardDao(database: HypoDatabase): ClipboardDao = database.clipboardDao()

    @Provides
    @Singleton
    fun provideRepository(dao: ClipboardDao): ClipboardRepository = ClipboardRepositoryImpl(dao)

    @Provides
    @Singleton
    fun provideNonceGenerator(): NonceGenerator = SecureRandomNonceGenerator()

    @Provides
    @Singleton
    fun provideCryptoService(nonceGenerator: NonceGenerator): CryptoService =
        CryptoService(nonceGenerator)

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
    fun provideLanTlsWebSocketConfig(): TlsWebSocketConfig =
        TlsWebSocketConfig(
            url = "wss://127.0.0.1:${TransportManager.DEFAULT_PORT}/ws",
            fingerprintSha256 = null
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
    fun provideCloudTlsWebSocketConfig(): TlsWebSocketConfig =
        TlsWebSocketConfig(
            url = BuildConfig.RELAY_WS_URL,
            fingerprintSha256 = BuildConfig.RELAY_CERT_FINGERPRINT.takeIf { it.isNotBlank() },
            headers = mapOf(
                "X-Hypo-Client" to BuildConfig.VERSION_NAME,
                "X-Hypo-Environment" to BuildConfig.RELAY_ENVIRONMENT
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
    fun provideSyncTransport(
        @Named("lan_ws_config") config: TlsWebSocketConfig,
        @Named("lan_ws_connector") connector: WebSocketConnector,
        frameCodec: TransportFrameCodec,
        analytics: TransportAnalytics
    ): SyncTransport = LanWebSocketClient(
        config,
        connector,
        frameCodec,
        CoroutineScope(SupervisorJob() + Dispatchers.IO),
        Clock.systemUTC(),
        analytics = analytics
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
        discoverySource: LanDiscoverySource,
        registrationController: LanRegistrationController,
        analytics: TransportAnalytics
    ): TransportManager = TransportManager(discoverySource, registrationController, analytics = analytics)
}
