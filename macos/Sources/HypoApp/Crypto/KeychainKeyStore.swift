import Foundation
import CryptoKit

#if canImport(Security)
import Security

public final class KeychainKeyStore: Sendable {
    public enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case dataEncodingFailed
    }

    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.hypo.clipboard.keys", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }
    
    /// Normalizes device ID for consistent storage and lookup.
    /// - Removes platform prefix if present (macos-/android-)
    /// - Converts to lowercase
    /// - Returns pure UUID in lowercase
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

    public func save(key: SymmetricKey, for deviceId: String) throws {
        let normalizedId = normalizeDeviceId(deviceId)
        let data = key.withUnsafeBytes { Data($0) }
        var query = baseQuery(for: normalizedId)
        query[kSecValueData as String] = data
        // Set accessibility to avoid password prompts - accessible after first unlock
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(baseQuery(for: normalizedId) as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func load(for deviceId: String) throws -> SymmetricKey? {
        let normalizedId = normalizeDeviceId(deviceId)
        
        // Try normalized ID first (primary lookup)
        if let key = try loadInternal(for: normalizedId) {
            return key
        }
        
        // Fallback: Try original device ID (for backward compatibility with old keys)
        if deviceId != normalizedId {
            if let key = try loadInternal(for: deviceId) {
                // Migrate to normalized ID for future lookups
                let keyData = key.withUnsafeBytes { Data($0) }
                try? save(key: SymmetricKey(data: keyData), for: normalizedId)
                try? delete(for: deviceId)
                return key
            }
        }
        
        // Fallback: Try with platform prefix (for backward compatibility)
        if !deviceId.hasPrefix("macos-") && !deviceId.hasPrefix("android-") {
            // Try with "macos-" prefix
            if let key = try loadInternal(for: "macos-\(deviceId)") {
                // Migrate to normalized ID
                let keyData = key.withUnsafeBytes { Data($0) }
                try? save(key: SymmetricKey(data: keyData), for: normalizedId)
                try? delete(for: "macos-\(deviceId)")
                return key
            }
            
            // Try with "android-" prefix
            if let key = try loadInternal(for: "android-\(deviceId)") {
                // Migrate to normalized ID
                let keyData = key.withUnsafeBytes { Data($0) }
                try? save(key: SymmetricKey(data: keyData), for: normalizedId)
                try? delete(for: "android-\(deviceId)")
                return key
            }
        }
        
        return nil
    }
    
    private func loadInternal(for deviceId: String) throws -> SymmetricKey? {
        var query = baseQuery(for: deviceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainError.dataEncodingFailed
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(for deviceId: String) throws {
        let normalizedId = normalizeDeviceId(deviceId)
        let status = SecItemDelete(baseQuery(for: normalizedId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for deviceId: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId
        ]

        #if !os(macOS)
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #endif

        return query
    }
}
#else

public final class KeychainKeyStore: Sendable {
    public enum KeychainError: Error {
        case unavailable
    }

    public init(service: String = "com.hypo.clipboard.keys", accessGroup: String? = nil) {}

    public func save(key: SymmetricKey, for deviceId: String) throws {
        throw KeychainError.unavailable
    }

    public func load(for deviceId: String) throws -> SymmetricKey? {
        throw KeychainError.unavailable
    }

    public func delete(for deviceId: String) throws {
        throw KeychainError.unavailable
    }
}

#endif
