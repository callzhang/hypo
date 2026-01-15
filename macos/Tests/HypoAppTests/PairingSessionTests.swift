import Foundation
import Testing
@testable import HypoApp
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@MainActor
struct PairingSessionTests {
    @Test
    func testGeneratesPairingPayloadAndProcessesChallenge() async throws {
        let identity = UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!
        let signingStore = makeSigningKeyStore()
        let crypto = CryptoService()
        let storedDeviceIds = Locked<Set<String>>([])
        let session = PairingSession(
            identity: identity,
            signingKeyStore: signingStore,
            cryptoService: crypto,
            storeSharedKey: { key, deviceId in
                _ = key
                storedDeviceIds.withLock { $0.insert(deviceId) }
            },
            clock: { Date(timeIntervalSince1970: 0) }
        )

        try session.start(with: PairingSession.Configuration(service: "_hypo._tcp.local", port: 7010, relayHint: nil, deviceName: "Test Mac"))
        let payload = try #require(session.currentPayload())

        let androidKey = Curve25519.KeyAgreement.PrivateKey()
        let macPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.peerPublicKey)
        let sharedSecret = try await crypto.deriveKey(privateKey: androidKey, publicKey: macPub)

        let challengeData = Data("handshake".utf8)
        let challengePayload = PairingChallengePayload(challenge: challengeData, timestamp: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let challengeJSON = try encoder.encode(challengePayload)
        let androidDeviceId = UUID().uuidString.lowercased()
        let encrypted = try await crypto.encrypt(
            plaintext: challengeJSON,
            key: sharedSecret,
            aad: Data(androidDeviceId.utf8)
        )
        let message = try makeChallengeMessage(
            challengeId: UUID(),
            initiatorDeviceId: androidDeviceId,
            initiatorDeviceName: "Pixel",
            initiatorPublicKey: androidKey.publicKey.rawRepresentation,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )

        let ack = await session.handleChallenge(message)
        #expect(ack != nil)
        #expect(!storedDeviceIds.withLock { $0.isEmpty })
    }

    @Test
    func testHandleChallengeFailsWhenPayloadExpired() async throws {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 0))
        let (session, payload, crypto) = try makeSession(clock: clock, payloadValidity: 1)
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
        #expect(ack == nil)
        if case .failed(let reason) = session.state {
            #expect(reason == "Pairing payload expired")
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func testHandleChallengeFailsWhenChallengeOutsideTolerance() async throws {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 0))
        let (session, payload, crypto) = try makeSession(clock: clock, payloadValidity: 600, challengeTolerance: 2)
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
        #expect(ack == nil)
        if case .failed(let reason) = session.state {
            #expect(reason == "Challenge timestamp is outside the allowed window")
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func testHandleChallengeFailsForInvalidChallengePayload() async throws {
        let clock = MutableClock(now: Date(timeIntervalSince1970: 0))
        let (session, payload, crypto) = try makeSession(clock: clock)

        let (message, _, _, _) = try await makeChallengeMessage(
            payload: payload,
            plaintext: Data("not json".utf8),
            crypto: crypto
        )

        let ack = await session.handleChallenge(message)
        #expect(ack == nil)
        if case .failed(let reason) = session.state {
            #expect(reason == "Unable to decode pairing challenge")
        } else {
            #expect(Bool(false))
        }
    }

    @Test
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
        #expect(!corruptedCiphertext.isEmpty)
        corruptedCiphertext[0] ^= 0xFF

        let tampered = try makeChallengeMessage(
            challengeId: message.challengeId,
            initiatorDeviceId: message.initiatorDeviceId,
            initiatorDeviceName: message.initiatorDeviceName,
            initiatorPublicKey: message.initiatorPublicKey,
            nonce: message.nonce,
            ciphertext: Data(corruptedCiphertext),
            tag: message.tag
        )

        let ack = await session.handleChallenge(tampered)
        #expect(ack == nil)
        if case .failed(let reason) = session.state {
            #expect(reason == "Cryptographic operation failed")
        } else {
            #expect(Bool(false))
        }
    }
}

private final class MutableClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(to newValue: Date) {
        now = newValue
    }
}

private extension PairingSessionTests {
    func makeSession(
        clock: MutableClock,
        payloadValidity: TimeInterval = 300,
        challengeTolerance: TimeInterval = 30
    ) throws -> (PairingSession, PairingPayload, CryptoService) {
        let crypto = CryptoService()
        let session = PairingSession(
            identity: UUID(),
            signingKeyStore: makeSigningKeyStore(),
            cryptoService: crypto,
            storeSharedKey: { _, _ in },
            clock: { clock.now }
        )

        try session.start(with: PairingSession.Configuration(
            service: "_hypo._tcp.local",
            port: 7010,
            relayHint: nil,
            payloadValidity: payloadValidity,
            challengeTolerance: challengeTolerance,
            deviceName: "Test Mac"
        ))

        let payload = try #require(session.currentPayload())
        return (session, payload, crypto)
    }

    func makeChallengeMessage(
        payload: PairingPayload,
        plaintext: Data,
        crypto: CryptoService,
        androidDeviceId: String = UUID().uuidString.lowercased()
    ) async throws -> (PairingChallengeMessage, SymmetricKey, Curve25519.KeyAgreement.PrivateKey, String) {
        let androidKey = Curve25519.KeyAgreement.PrivateKey()
        let macPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.peerPublicKey)
        let sharedSecret = try await crypto.deriveKey(privateKey: androidKey, publicKey: macPublicKey)
        let encrypted = try await crypto.encrypt(
            plaintext: plaintext,
            key: sharedSecret,
            aad: Data(androidDeviceId.utf8)
        )

        let message = try makeChallengeMessage(
            challengeId: UUID(),
            initiatorDeviceId: androidDeviceId,
            initiatorDeviceName: "Pixel",
            initiatorPublicKey: androidKey.publicKey.rawRepresentation,
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

    func makeChallengeMessage(
        challengeId: UUID,
        initiatorDeviceId: String,
        initiatorDeviceName: String,
        initiatorPublicKey: Data,
        nonce: Data,
        ciphertext: Data,
        tag: Data
    ) throws -> PairingChallengeMessage {
        let payload: [String: String] = [
            "challenge_id": challengeId.uuidString.lowercased(),
            "initiator_device_id": initiatorDeviceId,
            "initiator_device_name": initiatorDeviceName,
            "initiator_pub_key": initiatorPublicKey.base64EncodedString(),
            "nonce": nonce.base64EncodedString(),
            "ciphertext": ciphertext.base64EncodedString(),
            "tag": tag.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return try JSONDecoder().decode(PairingChallengeMessage.self, from: data)
    }

    func makeSigningKeyStore() -> FileBasedPairingSigningKeyStore {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return FileBasedPairingSigningKeyStore(storageDirectory: tempDir)
    }
}
