import Foundation
import CryptoKit
import Testing
import HypoCore
@testable import HypoiOS

/// Removing a paired device.
///
/// The UI test for this can only skip when nothing happens to be paired on the
/// machine running it, so the behaviour is pinned here instead.
@Suite("Unpairing")
struct UnpairTests {
    private func makeDevice(id: String) -> PairedDevice {
        PairedDevice(
            id: id,
            name: "OPPO PLP110",
            platform: "android",
            lastSeen: Date(),
            isOnline: false,
            serviceName: nil,
            bonjourHost: nil,
            bonjourPort: nil,
            fingerprint: nil
        )
    }

    @Test("the device stops being listed")
    @MainActor
    func removesTheDevice() async {
        let context = HypoiOSContext(historyStore: HistoryStore())
        let device = makeDevice(id: "unpair-test-\(UUID().uuidString)")
        context.transportManager.registerPairedDevice(device)
        #expect(context.transportManager.pairedDevices.contains { $0.id == device.id })

        context.unpair(device)

        #expect(context.transportManager.pairedDevices.contains { $0.id == device.id } == false)
    }

    @Test("its key is gone too")
    @MainActor
    func removesTheKey() async throws {
        let context = HypoiOSContext(historyStore: HistoryStore())
        let device = makeDevice(id: "unpair-key-\(UUID().uuidString)")
        // A device left listed with no key looks broken rather than removed,
        // so the key must go with it.
        try context.deviceKeyProvider.store(key: SymmetricKey(size: .bits256), for: device.id)
        _ = try await context.deviceKeyProvider.key(for: device.id)

        context.transportManager.registerPairedDevice(device)
        context.unpair(device)

        await #expect(throws: (any Error).self) {
            _ = try await context.deviceKeyProvider.key(for: device.id)
        }
    }

    @Test("removing one leaves the others alone")
    @MainActor
    func leavesOtherDevices() async {
        let context = HypoiOSContext(historyStore: HistoryStore())
        let going = makeDevice(id: "unpair-going-\(UUID().uuidString)")
        let staying = makeDevice(id: "unpair-staying-\(UUID().uuidString)")
        context.transportManager.registerPairedDevice(going)
        context.transportManager.registerPairedDevice(staying)

        context.unpair(going)

        #expect(context.transportManager.pairedDevices.contains { $0.id == staying.id })
        context.unpair(staying)
    }
}
