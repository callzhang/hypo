package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.SyncEnvelope

internal sealed interface LoopEvent {
    data object ChannelClosed : LoopEvent
    data object ConnectionClosed : LoopEvent
    data class Envelope(val envelope: SyncEnvelope) : LoopEvent
}

