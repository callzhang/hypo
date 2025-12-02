import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

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
        guard let key = try keychain.load(for: deviceId) else {
            throw DeviceKeyProviderError.missingKey(deviceId)
        }
        return key
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
