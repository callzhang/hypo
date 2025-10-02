package com.hypo.clipboard.di

import android.content.Context
import androidx.room.Room
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
import com.hypo.clipboard.sync.NoopSyncTransport
import com.hypo.clipboard.sync.SyncTransport
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

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
    fun provideSyncTransport(): SyncTransport = NoopSyncTransport()
}
