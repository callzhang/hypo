package com.hypo.clipboard.sync

/**
 * Exception thrown when a payload is too large to be sent over the transport layer.
 * This is a recoverable error - the sync should be skipped rather than crashing.
 */
class TransportPayloadTooLargeException(
    message: String,
    cause: Throwable? = null
) : Exception(message, cause)



