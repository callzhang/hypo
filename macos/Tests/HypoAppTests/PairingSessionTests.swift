import XCTest
@testable import HypoApp
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class PairingSessionTests: XCTestCase {
    func testGeneratesQrPayloadAndProcessesChallenge() async throws {
        let identity = UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!
        let signingStore = PairingSigningKeyStore()
        let crypto = CryptoService()
        var storedKeys: [String: SymmetricKey] = [:]
        let session = PairingSession(
            identity: identity,
            signingKeyStore: signingStore,
            cryptoService: crypto,
            storeSharedKey: { key, deviceId in
                storedKeys[deviceId] = key
            },
            clock: { Date(timeIntervalSince1970: 0) }
        )

        try session.start(with: .init(service: "_hypo._tcp.local", port: 7010, relayHint: nil, deviceName: "Test Mac"))
        let payload = try decodePayload(from: session)

        let androidKey = Curve25519.KeyAgreement.PrivateKey()
        let macPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.macPublicKey)
        let sharedSecret = try await crypto.deriveKey(privateKey: androidKey, publicKey: macPub)

        let challengeData = Data("handshake".utf8)
        let challengePayload = PairingChallengePayload(challenge: challengeData, timestamp: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let challengeJSON = try encoder.encode(challengePayload)
        let androidDeviceId = UUID().uuidString
        let encrypted = try await crypto.encrypt(
            plaintext: challengeJSON,
            key: sharedSecret,
            aad: Data(androidDeviceId.utf8)
        )
        let message = PairingChallengeMessage(
            challengeId: UUID(),
            androidDeviceId: androidDeviceId,
            androidDeviceName: "Pixel",
            androidPublicKey: androidKey.publicKey.rawRepresentation,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )

        let ack = await session.handleChallenge(message)
        XCTAssertNotNil(ack)
        XCTAssertFalse(storedKeys.isEmpty)
    }

    func testHandleChallengeFailsWhenQrExpired() async throws {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 0))
        let (session, payload, crypto) = try makeSession(clock: clock, qrValidity: 1)
        clock.advance(to: Date(timeIntervalSince1970: 10))

        let challengePayload = try encodeChallengePayload(
            challenge: Data("handshake".utf8),
            timestamp: clock.now
        )
        let (message, _, _, _) = try await makeChallengeMessage(
            payload: payload,
            plaintext: challengePayload,
            crypto: crypto
        )

        let ack = await session.handleChallenge(message)
        XCTAssertNil(ack)
        if case .failed(let reason) = session.state {
            XCTAssertEqual(reason, "Pairing QR code expired")
        } else {
            XCTFail("Expected failure state for expired QR payload")
        }
    }

    func testHandleChallengeFailsWhenChallengeOutsideTolerance() async throws {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 0))
        let (session, payload, crypto) = try makeSession(clock: clock, qrValidity: 600, challengeTolerance: 2)
        clock.advance(to: Date(timeIntervalSince1970: 10))

        let challengePayload = try encodeChallengePayload(
            challenge: Data("late".utf8),
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let (message, _, _, _) = try await makeChallengeMessage(
            payload: payload,
            plaintext: challengePayload,
            crypto: crypto
        )

        let ack = await session.handleChallenge(message)
        XCTAssertNil(ack)
        if case .failed(let reason) = session.state {
            XCTAssertEqual(reason, "Challenge timestamp is outside the allowed window")
        } else {
            XCTFail("Expected failure for stale challenge payload")
        }
    }

    func testHandleChallengeFailsForInvalidChallengePayload() async throws {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 0))
        let (session, payload, crypto) = try makeSession(clock: clock)

        let (message, _, _, _) = try await makeChallengeMessage(
            payload: payload,
            plaintext: Data("not json".utf8),
            crypto: crypto
        )

        let ack = await session.handleChallenge(message)
        XCTAssertNil(ack)
        if case .failed(let reason) = session.state {
            XCTAssertEqual(reason, "Unable to decode pairing challenge")
        } else {
            XCTFail("Expected failure for invalid challenge payload")
        }
    }

    func testHandleChallengeFailsWhenCiphertextIsTampered() async throws {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 0))
        let (session, payload, crypto) = try makeSession(clock: clock)

        let challengePayload = try encodeChallengePayload(
            challenge: Data("integrity".utf8),
            timestamp: clock.now
        )
        let (message, _, _, _) = try await makeChallengeMessage(
            payload: payload,
            plaintext: challengePayload,
            crypto: crypto
        )

        var corruptedCiphertext = Array(message.ciphertext)
        XCTAssertFalse(corruptedCiphertext.isEmpty)
        corruptedCiphertext[0] ^= 0xFF

        let tampered = PairingChallengeMessage(
            challengeId: message.challengeId,
            androidDeviceId: message.androidDeviceId,
            androidDeviceName: message.androidDeviceName,
            androidPublicKey: message.androidPublicKey,
            nonce: message.nonce,
            ciphertext: Data(corruptedCiphertext),
            tag: message.tag
        )

        let ack = await session.handleChallenge(tampered)
        XCTAssertNil(ack)
        if case .failed(let reason) = session.state {
            XCTAssertEqual(reason, "Cryptographic operation failed")
        } else {
            XCTFail("Expected failure for tampered ciphertext")
        }
    }
}

private final class MutableClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(to newValue: Date) {
        now = newValue
    }
}

private extension PairingSessionTests {
    func decodePayload(from session: PairingSession) throws -> PairingPayload {
        let payloadJSON = try session.qrPayloadJSON()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PairingPayload.self, from: Data(payloadJSON.utf8))
    }

    func makeSession(
        clock: MutableClock,
        qrValidity: TimeInterval = 300,
        challengeTolerance: TimeInterval = 30
    ) throws -> (PairingSession, PairingPayload, CryptoService) {
        let crypto = CryptoService()
        let session = PairingSession(
            identity: UUID(),
            signingKeyStore: PairingSigningKeyStore(),
            cryptoService: crypto,
            storeSharedKey: { _, _ in },
            clock: { clock.now }
        )

        try session.start(with: .init(
            service: "_hypo._tcp.local",
            port: 7010,
            relayHint: nil,
            qrValidity: qrValidity,
            challengeTolerance: challengeTolerance,
            deviceName: "Test Mac"
        ))

        let payload = try decodePayload(from: session)
        return (session, payload, crypto)
    }

    func makeChallengeMessage(
        payload: PairingPayload,
        plaintext: Data,
        crypto: CryptoService,
        androidDeviceId: String = UUID().uuidString
    ) async throws -> (PairingChallengeMessage, SymmetricKey, Curve25519.KeyAgreement.PrivateKey, String) {
        let androidKey = Curve25519.KeyAgreement.PrivateKey()
        let macPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.macPublicKey)
        let sharedSecret = try await crypto.deriveKey(privateKey: androidKey, publicKey: macPublicKey)
        let encrypted = try await crypto.encrypt(
            plaintext: plaintext,
            key: sharedSecret,
            aad: Data(androidDeviceId.utf8)
        )

        let message = PairingChallengeMessage(
            challengeId: UUID(),
            androidDeviceId: androidDeviceId,
            androidDeviceName: "Pixel",
            androidPublicKey: androidKey.publicKey.rawRepresentation,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )

        return (message, sharedSecret, androidKey, androidDeviceId)
    }

    func encodeChallengePayload(challenge: Data, timestamp: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = PairingChallengePayload(challenge: challenge, timestamp: timestamp)
        return try encoder.encode(payload)
    }
}
