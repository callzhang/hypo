import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import HypoApp

struct CryptoServiceTests {
    @Test
    func testEncryptDecryptRoundTrip() async throws {
        let nonce = Data(repeating: 0xAB, count: 12)
        let service = CryptoService(nonceGenerator: DeterministicNonceGenerator(nonce: nonce))
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("hello, hypo".utf8)
        let aad = Data("device-id".utf8)

        let result = try await service.encrypt(plaintext: plaintext, key: key, aad: aad)
        #expect(result.nonce == nonce)
        let decrypted = try await service.decrypt(ciphertext: result.ciphertext, key: key, nonce: result.nonce, tag: result.tag, aad: aad)
        #expect(decrypted == plaintext)
    }

    @Test
    func testDecryptFailsWithTamperedCiphertext() async throws {
        let nonce = Data(repeating: 0xCD, count: 12)
        let service = CryptoService(nonceGenerator: DeterministicNonceGenerator(nonce: nonce))
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data("integrity".utf8)

        let result = try await service.encrypt(plaintext: plaintext, key: key, aad: nil)
        var corruptedCiphertext = Array(result.ciphertext)
        try #require(!corruptedCiphertext.isEmpty)
        corruptedCiphertext[0] ^= 0x01

        await expectThrows {
            try await service.decrypt(
                ciphertext: Data(corruptedCiphertext),
                key: key,
                nonce: result.nonce,
                tag: result.tag,
                aad: nil
            )
        }
    }

    @Test
    func testDeriveKeyProducesMatchingMaterial() async throws {
        let service = CryptoService()
        let aliceKey = Curve25519.KeyAgreement.PrivateKey()
        let bobKey = Curve25519.KeyAgreement.PrivateKey()

        let aliceDerived = try await service.deriveKey(privateKey: aliceKey, publicKey: bobKey.publicKey, salt: Data("salt".utf8), info: Data("info".utf8))
        let bobDerived = try await service.deriveKey(privateKey: bobKey, publicKey: aliceKey.publicKey, salt: Data("salt".utf8), info: Data("info".utf8))

        let aliceData = aliceDerived.withUnsafeBytes { Data($0) }
        let bobData = bobDerived.withUnsafeBytes { Data($0) }
        #expect(aliceData == bobData)
    }

    @Test
    func testDecryptMatchesSharedVector() async throws {
        let vectors = try loadCryptoVectors()
        let vector = try #require(vectors.testCases.first)

        let service = CryptoService(nonceGenerator: DeterministicNonceGenerator(nonce: vector.nonce))
        let key = SymmetricKey(data: vector.key)
        let decrypted = try await service.decrypt(
            ciphertext: vector.ciphertext,
            key: key,
            nonce: vector.nonce,
            tag: vector.tag,
            aad: vector.aad.isEmpty ? nil : vector.aad
        )

        #expect(decrypted == vector.plaintext)
    }

    @Test
    func testDeriveKeyMatchesSharedVector() async throws {
        let vectors = try loadCryptoVectors()
        let service = CryptoService()

        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: vectors.keyAgreement.alicePrivate)
        let bob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: vectors.keyAgreement.bobPrivate)

        let derived = try await service.deriveKey(privateKey: alice, publicKey: bob.publicKey)
        let derivedData = derived.withUnsafeBytes { Data($0) }

        #expect(derivedData == vectors.keyAgreement.sharedKey)
    }
}

private struct DeterministicNonceGenerator: NonceGenerating {
    let nonce: Data

    func generateNonce() throws -> Data {
        nonce
    }
}

private func loadCryptoVectors() throws -> CryptoVectors {
    let fileManager = FileManager.default
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
        url.deleteLastPathComponent()
        let candidate = url.appendingPathComponent("tests/crypto_test_vectors.json")
        if fileManager.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            return try JSONDecoder().decode(CryptoVectors.self, from: data)
        }
    }
    throw NSError(domain: "CryptoVectors", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to locate crypto_test_vectors.json"])
}

private struct CryptoVectors: Decodable {
    struct TestCase: Decodable {
        let name: String
        let plaintextBase64: String
        let keyBase64: String
        let nonceBase64: String
        let aadBase64: String
        let ciphertextBase64: String
        let tagBase64: String

        var plaintext: Data { Data(base64Encoded: plaintextBase64) ?? Data() }
        var key: Data { Data(base64Encoded: keyBase64) ?? Data() }
        var nonce: Data { Data(base64Encoded: nonceBase64) ?? Data() }
        var aad: Data { Data(base64Encoded: aadBase64) ?? Data() }
        var ciphertext: Data { Data(base64Encoded: ciphertextBase64) ?? Data() }
        var tag: Data { Data(base64Encoded: tagBase64) ?? Data() }

        private enum CodingKeys: String, CodingKey {
            case name
            case plaintextBase64 = "plaintext_base64"
            case keyBase64 = "key_base64"
            case nonceBase64 = "nonce_base64"
            case aadBase64 = "aad_base64"
            case ciphertextBase64 = "ciphertext_base64"
            case tagBase64 = "tag_base64"
        }
    }

    struct KeyAgreement: Decodable {
        let alicePrivateBase64: String
        let alicePublicBase64: String
        let bobPrivateBase64: String
        let bobPublicBase64: String
        let sharedKeyBase64: String

        var alicePrivate: Data { Data(base64Encoded: alicePrivateBase64) ?? Data() }
        var alicePublic: Data { Data(base64Encoded: alicePublicBase64) ?? Data() }
        var bobPrivate: Data { Data(base64Encoded: bobPrivateBase64) ?? Data() }
        var bobPublic: Data { Data(base64Encoded: bobPublicBase64) ?? Data() }
        var sharedKey: Data { Data(base64Encoded: sharedKeyBase64) ?? Data() }

        private enum CodingKeys: String, CodingKey {
            case alicePrivateBase64 = "alice_private_base64"
            case alicePublicBase64 = "alice_public_base64"
            case bobPrivateBase64 = "bob_private_base64"
            case bobPublicBase64 = "bob_public_base64"
            case sharedKeyBase64 = "shared_key_base64"
        }
    }

    let testCases: [TestCase]
    let keyAgreement: KeyAgreement

    enum CodingKeys: String, CodingKey {
        case testCases = "test_cases"
        case keyAgreement = "key_agreement"
    }

}
