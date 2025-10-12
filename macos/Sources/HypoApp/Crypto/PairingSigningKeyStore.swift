import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security

public enum PairingSigningKeyStoreError: Error {
    case unexpectedStatus(OSStatus)
    case encodingFailed
}

public final class PairingSigningKeyStore: Sendable {
    private let service = "com.hypo.clipboard.signing"
    private let account = "pairing-key"

    public init() {}

    public func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try load() {
            return existing
        }
        let key = Curve25519.Signing.PrivateKey()
        try save(key)
        return key
    }

    public func load() throws -> Curve25519.Signing.PrivateKey? {
        // Store as generic password data instead of cryptographic key
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw PairingSigningKeyStoreError.encodingFailed
            }
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        case errSecItemNotFound:
            return nil
        default:
            throw PairingSigningKeyStoreError.unexpectedStatus(status)
        }
    }

    public func save(_ key: Curve25519.Signing.PrivateKey) throws {
        let data = key.rawRepresentation
        
        // Store as generic password data instead of cryptographic key
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Update existing item
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let attributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw PairingSigningKeyStoreError.unexpectedStatus(updateStatus)
            }
        default:
            throw PairingSigningKeyStoreError.unexpectedStatus(status)
        }
    }
}
#else

public final class PairingSigningKeyStore: Sendable {
    public init() {}

    public func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    public func load() throws -> Curve25519.Signing.PrivateKey? {
        nil
    }

    public func save(_ key: Curve25519.Signing.PrivateKey) throws {}
}

#endif
