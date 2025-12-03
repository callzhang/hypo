import Foundation

public enum CloudRelayDefaults {
    public static func production(bundle: Bundle = .main) -> CloudRelayConfiguration {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let deviceIdentity = DeviceIdentity()
        return CloudRelayConfiguration(
            url: URL(string: "wss://hypo.fly.dev/ws")!,
            fingerprint: nil, // No certificate pinning for relay - standard TLS verification is sufficient
            headers: [
                "X-Hypo-Client": version,
                "X-Hypo-Environment": "production",
                "X-Device-Id": deviceIdentity.deviceIdString,
                "X-Device-Platform": "macos"
            ],
            idleTimeout: 30
        )
    }
    
    // Keep staging for backwards compatibility (returns production now)
    public static func staging(bundle: Bundle = .main) -> CloudRelayConfiguration {
        return production(bundle: bundle)
    }
}
