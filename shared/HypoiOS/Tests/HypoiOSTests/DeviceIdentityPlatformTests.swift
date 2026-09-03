import Foundation
import Testing
import HypoCore

@Suite("DeviceIdentity on iOS")
struct DeviceIdentityPlatformTests {
    @Test("a fresh identity reports the iOS platform")
    func freshIdentityIsIOS() throws {
        // A private suite, because the platform is persisted on first launch
        // and UserDefaults.standard may already carry a value from an earlier
        // run — which would make this pass or fail for the wrong reason.
        let suiteName = "com.hypo.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let identity = DeviceIdentity(userDefaults: defaults, hostname: "Test iPhone")

        // Was hardcoded to .macOS, so an iPhone introduced itself to peers as a
        // Mac — and kept doing so, because the value is written to UserDefaults
        // on first launch and read back from then on.
        #expect(identity.platform == .iOS)
    }

    @Test("an already-persisted platform is honoured")
    func persistedPlatformWins() throws {
        let suiteName = "com.hypo.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(UUID().uuidString, forKey: "com.hypo.clipboard.device_id")
        defaults.set("macos", forKey: "com.hypo.clipboard.device_platform")

        let identity = DeviceIdentity(userDefaults: defaults, hostname: "Test iPhone")

        // Existing installs keep the identity they already published to peers.
        #expect(identity.platform == .macOS)
    }
}
