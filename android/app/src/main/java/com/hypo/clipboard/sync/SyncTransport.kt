package com.hypo.clipboard.sync

interface SyncTransport {
    suspend fun send(envelope: SyncEnvelope)
}

class NoopSyncTransport : SyncTransport {
    override suspend fun send(envelope: SyncEnvelope) = Unit
}
