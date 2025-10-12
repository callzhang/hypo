import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security

// Define Ed25519 key type constant if not available
private let kSecAttrKeyTypeEd25519Available: String = {
    if #available(macOS 10.15, *) {
        return kSecAttrKeyTypeECSECPrimeRandom as String
    }
    return "com.apple.security.ec.ed25519" as String
}()

public enum PairingSigningKeyStoreError: Error {
    case unexpectedStatus(OSStatus)
    case encodingFailed
}

public final class PairingSigningKeyStore: Sendable {
    private let service = "com.hypo.clipboard.signing"

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
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: service,
            kSecAttrKeyType as String: kSecAttrKeyTypeEd25519Available,
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: service,
            kSecAttrKeyType as String: kSecAttrKeyTypeEd25519Available,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: service,
                kSecAttrKeyType as String: kSecAttrKeyTypeEd25519Available
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
