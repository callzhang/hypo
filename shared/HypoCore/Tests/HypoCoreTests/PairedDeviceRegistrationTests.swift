import Foundation
import Testing
@testable import HypoCore

/// Two devices that share a name are still two devices.
///
/// Registration used to fall back to matching on name and platform when no id
/// matched. Nothing carries a platform — every device stores "Unknown" — so
/// that reduced to matching on the name, and pairing a second device called
/// what the first one is called replaced it. The first device stayed listed
/// under someone else's id and quietly stopped syncing.
@MainActor
@Suite("Paired device registration")
struct PairedDeviceRegistrationTests {
    private func device(id: String, name: String, platform: String = "Unknown") -> PairedDevice {
        PairedDevice(
            id: id,
            name: name,
            platform: platform,
            lastSeen: Date(timeIntervalSince1970: 1_788_000_000),
            isOnline: false,
            serviceName: nil,
            bonjourHost: nil,
            bonjourPort: nil,
            fingerprint: nil
        )
    }

    private func makeManager() -> TransportManager {
        let server = LanWebSocketServer(localDeviceId: UUID().uuidString)
        return TransportManager(
            provider: DefaultTransportProvider(server: server),
            webSocketServer: server,
            defaults: UserDefaults(suiteName: "registration-\(UUID().uuidString)")!,
            notificationController: MockNotificationController(),
            clipboard: RecordingClipboard(),
            autoStartLanServices: false
        )
    }

    @Test("two devices with the same name both stay paired")
    func keepsBothSameNamedDevices() {
        let manager = makeManager()
        let first = device(id: "aaaa1111-0000-0000-0000-000000000001", name: "iPhone")
        let second = device(id: "bbbb2222-0000-0000-0000-000000000002", name: "iPhone")

        manager.registerPairedDevice(first)
        manager.registerPairedDevice(second)

        #expect(manager.pairedDevices.count == 2)
        #expect(manager.pairedDevices.contains { $0.id == first.id })
        #expect(manager.pairedDevices.contains { $0.id == second.id })
    }

    @Test("re-registering the same id updates rather than duplicates")
    func updatesSameDevice() {
        let manager = makeManager()
        let id = "cccc3333-0000-0000-0000-000000000003"
        manager.registerPairedDevice(device(id: id, name: "Mac"))
        manager.registerPairedDevice(device(id: id, name: "Renamed Mac"))

        #expect(manager.pairedDevices.count == 1)
        #expect(manager.pairedDevices.first?.name == "Renamed Mac")
    }

    @Test("a known platform still collapses a re-pair under a new id")
    func collapsesWhenPlatformIsKnown() {
        let manager = makeManager()
        manager.registerPairedDevice(device(id: "dddd4444-0000-0000-0000-000000000004", name: "Pixel", platform: "android"))
        manager.registerPairedDevice(device(id: "eeee5555-0000-0000-0000-000000000005", name: "Pixel", platform: "android"))

        // The original intent, which only applies once a platform is carried.
        #expect(manager.pairedDevices.count == 1)
    }
}
