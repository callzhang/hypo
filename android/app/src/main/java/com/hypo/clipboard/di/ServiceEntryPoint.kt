package com.hypo.clipboard.di

import com.hypo.clipboard.sync.SyncCoordinator
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface ServiceEntryPoint {
    fun syncCoordinator(): SyncCoordinator
}

