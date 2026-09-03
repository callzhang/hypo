import Foundation
import CryptoKit

/// Builds pairing challenges and checks the answers, with no transport of its
/// own.
///
/// Both ways of pairing need this and neither owns it: over the relay the
/// challenge travels as a field in an HTTP body, over the LAN it goes down a
/// web socket. Separating it also means the contract can be tested directly
/// against a real `PairingSession` with no network in the way, which is the
/// only thing that proves the two halves agree.
public struct PairingChallengeBuilder: Sendable {
    public enum Error: Swift.Error, LocalizedError {
        case invalidPeerKey
        case ackMismatch

        public var errorDescription: String? {
            switch self {
            case .invalidPeerKey:
                return "The other device published an unusable public key"
            case .ackMismatch:
                return "The other device answered with the wrong challenge response"
            }
        }
    }

    private let cryptoService: CryptoService
    private let deviceId: String
    private let deviceName: String
    private let clock: @Sendable () -> Date

    public init(
        cryptoService: CryptoService = CryptoService(),
        deviceId: String,
        deviceName: String,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.cryptoService = cryptoService
        self.deviceId = deviceId.lowercased()
        self.deviceName = deviceName
        self.clock = clock
    }

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


    /// Checks that the peer's ack answers the challenge we sent, which is what
    /// proves it derived the same key.
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
