import Foundation
import CryptoKit

/// File-based storage for pairing signing keys (replaces Keychain)
public enum FileBasedPairingSigningKeyStoreError: Error {
    case encodingFailed
    case decodingFailed
    case directoryCreationFailed
}

public final class FileBasedPairingSigningKeyStore: Sendable {
    private let storageDirectory: URL
    private let service = "com.hypo.clipboard.signing"
    private let filename = "pairing-key.key"
    
    public init(storageDirectory: URL? = nil) {
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
    
    private func fileURL() -> URL {
        return storageDirectory.appendingPathComponent(filename)
    }
    
    /// Encrypt data before storing
    private func encrypt(_ data: Data) -> Data {
        let key = SymmetricKey(data: SHA256.hash(data: service.data(using: .utf8)!))
        let sealedBox = try! AES.GCM.seal(data, using: key)
        var encrypted = sealedBox.nonce.withUnsafeBytes { Data($0) }
        encrypted.append(sealedBox.ciphertext)
        encrypted.append(sealedBox.tag)
        return encrypted
    }
    
    /// Decrypt data after loading
    private func decrypt(_ encryptedData: Data) throws -> Data {
        guard encryptedData.count >= 12 + 16 else {
            throw FileBasedPairingSigningKeyStoreError.decodingFailed
        }
        
        let nonceData = encryptedData.prefix(12)
        let tagData = encryptedData.suffix(16)
        let ciphertextData = encryptedData.dropFirst(12).dropLast(16)
        
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let key = SymmetricKey(data: SHA256.hash(data: service.data(using: .utf8)!))
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData)
        
        return try AES.GCM.open(sealedBox, using: key)
    }
    
    public func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try load() {
            return existing
        }
        let key = Curve25519.Signing.PrivateKey()
        try save(key)
        return key
    }
    
    public func load() throws -> Curve25519.Signing.PrivateKey? {
        let fileURL = self.fileURL()
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        do {
            let encryptedData = try Data(contentsOf: fileURL)
            let decryptedData = try decrypt(encryptedData)
            return try Curve25519.Signing.PrivateKey(rawRepresentation: decryptedData)
        } catch {
            throw FileBasedPairingSigningKeyStoreError.decodingFailed
        }
    }
    
    public func save(_ key: Curve25519.Signing.PrivateKey) throws {
        let data = key.rawRepresentation
        let encryptedData = encrypt(data)
        
        let fileURL = self.fileURL()
        try encryptedData.write(to: fileURL, options: [.atomic])
        
        // Set file permissions to be readable only by the user
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}


