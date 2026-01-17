import CryptoKit
import Foundation

public enum CloudRelayDefaults {
    public static func production(bundle: Bundle = .main) -> CloudRelayConfiguration {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let deviceIdentity = DeviceIdentity()
        var headers: [String: String] = [
            "X-Hypo-Client": version,
            "X-Hypo-Environment": "production",
            "X-Device-Id": deviceIdentity.deviceIdString,
            "X-Device-Platform": "macos"
        ]

        if let authToken = relayAuthToken(deviceId: deviceIdentity.deviceIdString, bundle: bundle) {
            headers["X-Auth-Token"] = authToken
        }

        return CloudRelayConfiguration(
            url: URL(string: "wss://hypo.fly.dev/ws")!,
            fingerprint: nil, // No certificate pinning for relay - standard TLS verification is sufficient
            headers: headers,
            idleTimeout: 30
        )
    }
    
    // Keep staging for backwards compatibility (returns production now)
    public static func staging(bundle: Bundle = .main) -> CloudRelayConfiguration {
        return production(bundle: bundle)
    }

    private static func relayAuthToken(deviceId: String, bundle: Bundle) -> String? {
        let environmentToken = ProcessInfo.processInfo.environment["RELAY_WS_AUTH_TOKEN"]
        let plistToken = bundle.object(forInfoDictionaryKey: "RelayWsAuthToken") as? String
        let secret = (environmentToken?.isEmpty == false ? environmentToken : nil)
            ?? (plistToken?.isEmpty == false ? plistToken : nil)
        guard let secret else { return nil }

        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(deviceId.utf8), using: key)
        return Data(mac).base64EncodedString()
    }
}
