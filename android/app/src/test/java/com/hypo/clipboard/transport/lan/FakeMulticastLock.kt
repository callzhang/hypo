package com.hypo.clipboard.transport.lan

internal class FakeMulticastLock : LanDiscoveryRepository.MulticastLockHandle {
    private var held = false
    var acquireCount: Int = 0
        private set
    var releaseCount: Int = 0
        private set

    override val isHeld: Boolean
        get() = held

    override fun acquire() {
        acquireCount += 1
        held = true
    }

    override fun release() {
        releaseCount += 1
        held = false
    }
}
