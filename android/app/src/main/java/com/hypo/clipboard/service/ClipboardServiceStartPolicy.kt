package com.hypo.clipboard.service

enum class ClipboardServiceStartMode {
    START_SERVICE,
    START_FOREGROUND_SERVICE
}

enum class ClipboardServiceStartReason {
    APP_LAUNCH,
    FORCE_PROCESS,
    BOOT_COMPLETED,
    PACKAGE_REPLACED,
    KEEP_ALIVE_WORKER,
    SERVICE_DESTROYED
}

object ClipboardServiceStartPolicy {
    fun resolveStartMode(
        sdkInt: Int,
        reason: ClipboardServiceStartReason
    ): ClipboardServiceStartMode {
        return if (sdkInt >= 26) {
            ClipboardServiceStartMode.START_FOREGROUND_SERVICE
        } else {
            ClipboardServiceStartMode.START_SERVICE
        }
    }
}
