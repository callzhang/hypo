import Foundation
import CryptoKit

public protocol NonceGenerating: Sendable {
    func generateNonce() throws -> Data
}

public struct CryptoNonceGenerator: NonceGenerating {
    public init() {}

    public func generateNonce() throws -> Data {
        let nonce = AES.GCM.Nonce()
        return nonce.withUnsafeBytes { Data($0) }
    }
}

private enum CryptoConstants {
    static let hkdfSalt = Data("hypo-clipboard-ecdh".utf8)
    static let hkdfInfo = Data("hypo-aes-256-gcm".utf8)
}

public actor CryptoService {
    public enum CryptoError: Error {
        case invalidNonce
    }

    private let nonceGenerator: NonceGenerating

    public init(nonceGenerator: NonceGenerating = CryptoNonceGenerator()) {
        self.nonceGenerator = nonceGenerator
    }

    public func encrypt(plaintext: Data, key: SymmetricKey, aad: Data? = nil) throws -> (ciphertext: Data, nonce: Data, tag: Data) {
        let nonceData = try nonceGenerator.generateNonce()
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw CryptoError.invalidNonce
        }
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad ?? Data())
        return (ciphertext: sealedBox.ciphertext, nonce: nonceData, tag: sealedBox.tag)
    }

    public func decrypt(ciphertext: Data, key: SymmetricKey, nonce nonceData: Data, tag: Data, aad: Data? = nil) throws -> Data {
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw CryptoError.invalidNonce
        }
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key, authenticating: aad ?? Data())
    }

    public func deriveKey(privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Curve25519.KeyAgreement.PublicKey, salt: Data? = nil, info: Data? = nil) throws -> SymmetricKey {
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt ?? CryptoConstants.hkdfSalt,
            sharedInfo: info ?? CryptoConstants.hkdfInfo,
            outputByteCount: 32
        )
    }
}
