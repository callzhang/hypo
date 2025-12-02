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
        // KeychainKeyStore handles normalization internally - no need to normalize here
        // It will try normalized ID first, then fallback to original format for backward compatibility
        if let key = try keychain.load(for: deviceId) {
            return key
        }
        
        throw DeviceKeyProviderError.missingKey(deviceId)
    }

    public func store(key: SymmetricKey, for deviceId: String) throws {
        // KeychainKeyStore handles normalization internally
        try keychain.save(key: key, for: deviceId)
    }

    public func delete(deviceId: String) throws {
        // KeychainKeyStore handles normalization internally
        try keychain.delete(for: deviceId)
    }
}

public actor InMemoryDeviceKeyProvider: DeviceKeyProviding {
    private var storage: [String: SymmetricKey]

    public init(storage: [String: SymmetricKey] = [:]) {
        self.storage = storage
    }
    
    /// Normalizes device ID for consistent storage and lookup (matches KeychainKeyStore behavior)
    private func normalizeDeviceId(_ deviceId: String) -> String {
        // Remove platform prefix if present
        let withoutPrefix: String
        if deviceId.hasPrefix("macos-") {
            withoutPrefix = String(deviceId.dropFirst("macos-".count))
        } else if deviceId.hasPrefix("android-") {
            withoutPrefix = String(deviceId.dropFirst("android-".count))
        } else {
            withoutPrefix = deviceId
        }
        // Normalize to lowercase for consistent storage
        return withoutPrefix.lowercased()
    }

    public func key(for deviceId: String) async throws -> SymmetricKey {
        let normalizedId = normalizeDeviceId(deviceId)
        guard let key = storage[normalizedId] else {
            throw DeviceKeyProviderError.missingKey(deviceId)
        }
        return key
    }

    public func setKey(_ key: SymmetricKey, for deviceId: String) async {
        let normalizedId = normalizeDeviceId(deviceId)
        storage[normalizedId] = key
    }
}
