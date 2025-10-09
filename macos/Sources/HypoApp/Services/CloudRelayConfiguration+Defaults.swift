import Foundation

public enum CloudRelayDefaults {
    public static func staging(bundle: Bundle = .main) -> CloudRelayConfiguration {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return CloudRelayConfiguration(
            url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
            fingerprint: "3f5d8b2ad3c6e6b0f1c2d4a9b6e8f0c1d2a3b4c5d6e7f8091a2b3c4d5e6f7089",
            headers: [
                "X-Hypo-Client": version,
                "X-Hypo-Environment": "staging"
            ],
            idleTimeout: 30
        )
    }
}
