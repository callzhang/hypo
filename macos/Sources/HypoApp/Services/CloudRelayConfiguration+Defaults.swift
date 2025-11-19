import Foundation

public enum CloudRelayDefaults {
    public static func production(bundle: Bundle = .main) -> CloudRelayConfiguration {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return CloudRelayConfiguration(
            url: URL(string: "wss://hypo.fly.dev/ws")!,
            fingerprint: nil, // No certificate pinning for relay - standard TLS verification is sufficient
            headers: [
                "X-Hypo-Client": version,
                "X-Hypo-Environment": "production"
            ],
            idleTimeout: 30
        )
    }
    
    // Keep staging for backwards compatibility (returns production now)
    public static func staging(bundle: Bundle = .main) -> CloudRelayConfiguration {
        return production(bundle: bundle)
    }
}
