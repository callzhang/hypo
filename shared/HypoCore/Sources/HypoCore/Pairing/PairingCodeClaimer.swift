import Foundation
import CryptoKit

/// Claims a pairing code that another device is showing, and completes the
/// handshake with it.
///
/// This is the counterpart to `PairingSession`, which shows a code and answers
/// challenges. Until now only Android and the .NET harness could take this
/// side, so two Swift clients could never pair with each other: both would sit
/// showing a code with nobody to claim it.
///
/// Naming is unavoidably confusing because the two layers disagree. The relay
/// calls the code's owner the "initiator" and the claimer the "responder";
/// `PairingChallengeMessage` uses those words the other way round, because
/// there the initiator is whoever initiates the challenge. This type speaks in
/// terms of "us" and "the peer" to stay out of it.
public struct PairingCodeClaimer: Sendable {
    /// Not Sendable: PairedDevice is not, and making it so is a wider change
    /// than this needs.
    public struct Result {
        public let peer: PairedDevice
        public let sharedKey: SymmetricKey
    }

    public enum Error: Swift.Error, LocalizedError {
        case ackNeverArrived
        case ackMismatch
        case invalidPeerKey

        public var errorDescription: String? {
            switch self {
            case .ackNeverArrived:
                return "The other device did not answer the pairing challenge"
            case .ackMismatch:
                return "The other device answered with the wrong challenge response"
            case .invalidPeerKey:
                return "The other device published an unusable public key"
            }
        }
    }

    private let relayClient: PairingRelayClient
    private let cryptoService: CryptoService
    private let deviceId: String
    private let deviceName: String
    private let clock: @Sendable () -> Date

    public init(
        relayClient: PairingRelayClient,
        cryptoService: CryptoService = CryptoService(),
        deviceId: String,
        deviceName: String,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.relayClient = relayClient
        self.cryptoService = cryptoService
        self.deviceId = deviceId.lowercased()
        self.deviceName = deviceName
        self.clock = clock
    }

    /// Claims `code`, sends a challenge, and waits for the answer.
    ///
    /// `pollInterval` and `timeout` bound the wait for the ack: the other
    /// device answers as soon as its poll loop notices the challenge, which is
    /// on its own timer, so this cannot be instant.
    public func claim(
        code: String,
        pollInterval: Duration = .milliseconds(1500),
        timeout: Duration = .seconds(60)
    ) async throws -> Result {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        let claimed = try await relayClient.claimPairingCode(
            code: code,
            responderDeviceId: deviceId,
            responderDeviceName: deviceName,
            responderPublicKey: ephemeral.publicKey.rawRepresentation
        )

        let challenge = try await makeChallenge(
            peerPublicKey: claimed.peerPublicKey,
            ephemeral: ephemeral
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let challengeJSON = String(
            decoding: try encoder.encode(challenge.message),
            as: UTF8.self
        )

        try await relayClient.submitChallenge(
            code: code,
            responderDeviceId: deviceId,
            challengeJSON: challengeJSON
        )

        let ack = try await waitForAck(
            code: code,
            pollInterval: pollInterval,
            timeout: timeout
        )

        try await verifyAck(ack, answers: challenge.challengeBytes, sharedKey: challenge.sharedKey)

        let peer = PairedDevice(
            id: ack.responderDeviceId.uuidString.lowercased(),
            name: ack.responderDeviceName,
            platform: "Unknown",
            lastSeen: clock(),
            isOnline: true
        )
        return Result(peer: peer, sharedKey: challenge.sharedKey)
    }

    /// The crypto half, separated from the relay half so it can be tested
    /// against a real `PairingSession` without a network in the way. That
    /// round trip is the only thing that proves the contract: the peer has to
    /// decrypt what this produces, and its ack has to verify here.
    public func makeChallenge(
        peerPublicKey peerPublicKeyData: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    ) async throws -> (message: PairingChallengeMessage, sharedKey: SymmetricKey, challengeBytes: Data) {
        guard let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerPublicKeyData
        ) else {
            throw Error.invalidPeerKey
        }

        let sharedKey = try await cryptoService.deriveKey(
            privateKey: ephemeral,
            publicKey: peerPublicKey
        )

        // 32 bytes the peer has to hand back the SHA-256 of, which is what
        // proves it holds the same shared key.
        var challengeBytes = Data(count: 32)
        challengeBytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let challengePayload = PairingChallengePayload(
            challenge: challengeBytes,
            timestamp: clock()
        )
        let sealed = try await cryptoService.encrypt(
            plaintext: try encoder.encode(challengePayload),
            key: sharedKey,
            // The peer decrypts with our device id as the AAD, so it has to be
            // the same string that goes into the message below.
            aad: Data(deviceId.utf8)
        )

        let message = PairingChallengeMessage(
            challengeId: UUID(),
            initiatorDeviceId: deviceId,
            initiatorDeviceName: deviceName,
            initiatorPublicKey: ephemeral.publicKey.rawRepresentation,
            nonce: sealed.nonce,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        return (message, sharedKey, challengeBytes)
    }

    private func waitForAck(
        code: String,
        pollInterval: Duration,
        timeout: Duration
    ) async throws -> PairingAckMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let clockSource = ContinuousClock()
        let deadline = clockSource.now.advanced(by: timeout)

        while clockSource.now < deadline {
            do {
                let ackJSON = try await relayClient.pollAck(
                    code: code,
                    responderDeviceId: deviceId
                )
                return try decoder.decode(PairingAckMessage.self, from: Data(ackJSON.utf8))
            } catch PairingRelayClient.Error.ackNotReady {
                try? await clockSource.sleep(for: pollInterval)
            }
        }
        throw Error.ackNeverArrived
    }

    public func verifyAck(
        _ ack: PairingAckMessage,
        answers challengeBytes: Data,
        sharedKey: SymmetricKey
    ) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The peer sealed the ack with its own device id as the AAD.
        let plaintext = try await cryptoService.decrypt(
            ciphertext: ack.ciphertext,
            key: sharedKey,
            nonce: ack.nonce,
            tag: ack.tag,
            aad: Data(ack.responderDeviceId.uuidString.lowercased().utf8)
        )
        let payload = try decoder.decode(PairingAckPayload.self, from: plaintext)
        guard payload.responseHash == Data(SHA256.hash(data: challengeBytes)) else {
            throw Error.ackMismatch
        }
    }
}
