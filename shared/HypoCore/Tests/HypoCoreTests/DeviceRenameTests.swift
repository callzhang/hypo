import Testing
import Foundation
@testable import HypoCore

/// Renaming this device.
///
/// The default name is whatever the OS calls the machine, which is often not
/// what its owner would call it, and it is the name every peer sees.
@Suite("Device rename")
struct DeviceRenameTests {
    private func freshDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "rename-\(UUID().uuidString)")!
        return suite
    }

    @Test("the new name sticks")
    func renames() {
        let defaults = freshDefaults()
        let identity = DeviceIdentity(userDefaults: defaults, hostname: "original")

        identity.rename(to: "Derek's iPhone")

        #expect(identity.deviceName == "Derek's iPhone")
    }

    @Test("it survives a restart")
    func persists() {
        let defaults = freshDefaults()
        DeviceIdentity(userDefaults: defaults, hostname: "original").rename(to: "Renamed")

        let reloaded = DeviceIdentity(userDefaults: defaults, hostname: "original")

        #expect(reloaded.deviceName == "Renamed")
    }

    @Test("blank input is refused")
    func rejectsBlank() {
        let defaults = freshDefaults()
        let identity = DeviceIdentity(userDefaults: defaults, hostname: "original")

        let kept = identity.rename(to: "   ")

        // A device with no name is worse than one named after the machine.
        #expect(kept == "original")
        #expect(identity.deviceName == "original")
    }

    @Test("a .local suffix is stripped, as it is on first run")
    func stripsLocalSuffix() {
        let defaults = freshDefaults()
        let identity = DeviceIdentity(userDefaults: defaults, hostname: "original")

        identity.rename(to: "studio.local")

        #expect(identity.deviceName == "studio")
    }

    @Test("renaming does not change the device id")
    func keepsIdentity() {
        let defaults = freshDefaults()
        let identity = DeviceIdentity(userDefaults: defaults, hostname: "original")
        let before = identity.deviceIdString

        identity.rename(to: "Something Else")

        // Peers key their stored keys off the id; changing it would unpair.
        #expect(identity.deviceIdString == before)
    }
}
