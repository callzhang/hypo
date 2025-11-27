import Foundation
import CryptoKit

public protocol DeviceKeyProviding: Sendable {
    func key(for deviceId: String) async throws -> SymmetricKey
}

public enum DeviceKeyProviderError: LocalizedError {
    case missingKey(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let deviceId):
            return "No symmetric key registered for device \(deviceId)"
        }
    }
}

public final class KeychainDeviceKeyProvider: DeviceKeyProviding {
    private let keychain: KeychainKeyStore

    public init(keychain: KeychainKeyStore = KeychainKeyStore()) {
        self.keychain = keychain
    }

    public func key(for deviceId: String) async throws -> SymmetricKey {
        // Try exact deviceId first (should be pure UUID now after system upgrade)
        if let key = try keychain.load(for: deviceId) {
            return key
        }
        
        // Fallback: Try removing any platform prefix (for backward compatibility during migration)
        // This handles old keys that might still have "android-" prefix
        if deviceId.hasPrefix("android-") {
            let unprefixedId = String(deviceId.dropFirst("android-".count))
            if let key = try keychain.load(for: unprefixedId) {
                return key
            }
        }
        
        // Fallback: If deviceId is pure UUID, try with "android-" prefix (for old keys)
        // This handles the case where keys were stored with the prefix before upgrade
        if deviceId.count == 36 && !deviceId.hasPrefix("android-") && !deviceId.hasPrefix("macos-") {
            let prefixedId = "android-\(deviceId)"
            if let key = try keychain.load(for: prefixedId) {
                return key
            }
        }
        
        throw DeviceKeyProviderError.missingKey(deviceId)
    }

    public func store(key: SymmetricKey, for deviceId: String) throws {
        try keychain.save(key: key, for: deviceId)
    }

    public func delete(deviceId: String) throws {
        try keychain.delete(for: deviceId)
    }
}

public actor InMemoryDeviceKeyProvider: DeviceKeyProviding {
    private var storage: [String: SymmetricKey]

    public init(storage: [String: SymmetricKey] = [:]) {
        self.storage = storage
    }

    public func key(for deviceId: String) async throws -> SymmetricKey {
        guard let key = storage[deviceId] else {
            throw DeviceKeyProviderError.missingKey(deviceId)
        }
        return key
    }

    public func setKey(_ key: SymmetricKey, for deviceId: String) async {
        storage[deviceId] = key
    }
}
