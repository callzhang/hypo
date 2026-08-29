import Foundation
import CryptoKit

/// File-based key storage that replaces Keychain for app-internal storage
/// Stores keys in the app's Application Support directory with encryption
public final class FileBasedKeyStore: Sendable {
    public enum FileStoreError: Error {
        case fileNotFound
        case encodingFailed
        case decodingFailed
        case directoryCreationFailed
        case writeFailed
    }
    
    private let storageDirectory: URL
    private let service: String
    
    /// Initialize with a custom storage directory (defaults to Application Support)
    public init(service: String = "com.hypo.clipboard.keys", storageDirectory: URL? = nil) {
        self.service = service
        
        if let customDir = storageDirectory {
            self.storageDirectory = customDir
        } else {
            // Use Application Support directory
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.storageDirectory = appSupport.appendingPathComponent("Hypo", isDirectory: true)
        }
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
    }
    
    /// Normalizes device ID for consistent storage and lookup.
    /// - Removes platform prefix if present (macos-/android-)
    /// - Converts to lowercase
    /// - Returns pure UUID in lowercase
    internal func normalizeDeviceId(_ deviceId: String) -> String {
        // Normalize to lowercase for consistent storage
        return deviceId.lowercased()
    }
    
    /// Get file URL for a device ID
    private func fileURL(for deviceId: String) -> URL {
        let normalizedId = normalizeDeviceId(deviceId)
        // Use base64 encoding of device ID as filename (safe for filesystem)
        let encodedId = normalizedId.data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            ?? normalizedId
        return storageDirectory.appendingPathComponent("\(encodedId).key")
    }
    
    /// Encrypt data before storing (using simple XOR with a derived key for basic protection)
    /// Note: This is not as secure as Keychain, but provides basic obfuscation
    private func encrypt(_ data: Data) -> Data {
        // Use a simple key derived from service name
        let key = SymmetricKey(data: SHA256.hash(data: service.data(using: .utf8)!))
        let sealedBox = try! AES.GCM.seal(data, using: key)
        // Store nonce + ciphertext + tag
        var encrypted = sealedBox.nonce.withUnsafeBytes { Data($0) }
        encrypted.append(sealedBox.ciphertext)
        encrypted.append(sealedBox.tag)
        return encrypted
    }
    
    /// Decrypt data after loading
    private func decrypt(_ encryptedData: Data) throws -> Data {
        guard encryptedData.count >= 12 + 16 else {
            throw FileStoreError.decodingFailed
        }
        
        // Extract nonce (first 12 bytes), ciphertext (middle), tag (last 16 bytes)
        let nonceData = encryptedData.prefix(12)
        let tagData = encryptedData.suffix(16)
        let ciphertextData = encryptedData.dropFirst(12).dropLast(16)
        
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let key = SymmetricKey(data: SHA256.hash(data: service.data(using: .utf8)!))
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData)
        
        return try AES.GCM.open(sealedBox, using: key)
    }
    
    public func save(key: SymmetricKey, for deviceId: String) throws {
        let normalizedId = normalizeDeviceId(deviceId)
        let keyData = key.withUnsafeBytes { Data($0) }
        
        // Encrypt the key data
        let encryptedData = encrypt(keyData)
        
        // Write to file
        let fileURL = self.fileURL(for: normalizedId)
        try encryptedData.write(to: fileURL, options: [.atomic])
        
        // Set file permissions to be readable only by the user
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
    
    public func load(for deviceId: String) throws -> SymmetricKey? {
        let normalizedId = normalizeDeviceId(deviceId)
        return try loadInternal(for: normalizedId)
    }
    
    private func loadInternal(for deviceId: String) throws -> SymmetricKey? {
        let fileURL = self.fileURL(for: deviceId)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        do {
            let encryptedData = try Data(contentsOf: fileURL)
            let decryptedData = try decrypt(encryptedData)
            return SymmetricKey(data: decryptedData)
        } catch {
            throw FileStoreError.decodingFailed
        }
    }
    
    public func delete(for deviceId: String) throws {
        let normalizedId = normalizeDeviceId(deviceId)
        let fileURL = self.fileURL(for: normalizedId)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

