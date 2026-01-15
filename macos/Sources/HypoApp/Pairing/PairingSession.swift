import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public protocol PairingSessionDelegate: AnyObject {
    func pairingSession(_ session: PairingSession, didCompleteWith device: PairedDevice)
    func pairingSession(_ session: PairingSession, didFailWith error: Error)
}

public enum PairingSessionError: LocalizedError {
    case invalidSignature
    case payloadExpired
    case duplicateChallenge
    case challengeWindowTooOld
    case invalidChallengePayload
    case cryptoFailure

    public var errorDescription: String? {
        switch self {
        case .invalidSignature:
            return "Pairing signature verification failed"
        case .payloadExpired:
            return "Pairing payload expired"
        case .duplicateChallenge:
            return "Challenge already processed"
        case .challengeWindowTooOld:
            return "Challenge timestamp is outside the allowed window"
        case .invalidChallengePayload:
            return "Unable to decode pairing challenge"
        case .cryptoFailure:
            return "Cryptographic operation failed"
        }
    }
}

public final class PairingSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var service: String
        public var port: Int
        public var relayHint: URL?
        public var payloadValidity: TimeInterval
        public var challengeTolerance: TimeInterval
        public var deviceName: String

        public init(
            service: String,
            port: Int,
            relayHint: URL?,
            payloadValidity: TimeInterval = 300,
            challengeTolerance: TimeInterval = 30,
            deviceName: String
        ) {
            self.service = service
            self.port = port
            self.relayHint = relayHint
            self.payloadValidity = payloadValidity
            self.challengeTolerance = challengeTolerance
            self.deviceName = deviceName
        }
    }

    public enum State {
        case idle
        case displaying(payload: PairingPayload)
        case awaitingChallenge(payload: PairingPayload)
        case completed(device: PairedDevice)
        case failed(String)
    }

    private let identity: UUID
    private let signingKeyStore: FileBasedPairingSigningKeyStore
    private let cryptoService: CryptoService
    private let storeSharedKeyHandler: @Sendable (SymmetricKey, String) throws -> Void
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder
    private let clock: () -> Date
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var lastChallenges: [UUID] = []
    private var configuration: Configuration?
    public private(set) var state: State = .idle
    public weak var delegate: PairingSessionDelegate?

    public init(
        identity: UUID,
        signingKeyStore: FileBasedPairingSigningKeyStore = FileBasedPairingSigningKeyStore(),
        cryptoService: CryptoService = CryptoService(),
        deviceKeyProvider: KeychainDeviceKeyProvider = KeychainDeviceKeyProvider(),
        storeSharedKey: (@Sendable (SymmetricKey, String) throws -> Void)? = nil,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.identity = identity
        self.signingKeyStore = signingKeyStore
        self.cryptoService = cryptoService
        if let storeSharedKey {
            self.storeSharedKeyHandler = storeSharedKey
        } else {
            self.storeSharedKeyHandler = { key, deviceId in
                try deviceKeyProvider.store(key: key, for: deviceId)
            }
        }
        self.clock = clock
        self.jsonEncoder = JSONEncoder()
        self.jsonDecoder = JSONDecoder()
        self.jsonEncoder.dateEncodingStrategy = .iso8601
        self.jsonDecoder.dateDecodingStrategy = .iso8601
    }

    public func start(
        with configuration: Configuration,
        keyAgreementKey: Curve25519.KeyAgreement.PrivateKey? = nil
    ) throws {
        self.configuration = configuration
        let signingKey = try signingKeyStore.loadOrCreate()
        let agreementKey = keyAgreementKey ?? Curve25519.KeyAgreement.PrivateKey()
        self.ephemeralKey = agreementKey

        let issuedAt = clock()
        let expiresAt = issuedAt.addingTimeInterval(configuration.payloadValidity)
        let payload = PairingPayload(
            peerDeviceId: identity,
            peerPublicKey: agreementKey.publicKey.rawRepresentation,
            peerSigningPublicKey: signingKey.publicKey.rawRepresentation,
            service: configuration.service,
            port: configuration.port,
            relayHint: configuration.relayHint,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signature: Data()
        )

        let signature = try signPayload(payload, signingKey: signingKey)
        let signedPayload = PairingPayload(
            version: payload.version,
            peerDeviceId: payload.peerDeviceId,
            peerPublicKey: payload.peerPublicKey,
            peerSigningPublicKey: payload.peerSigningPublicKey,
            service: payload.service,
            port: payload.port,
            relayHint: payload.relayHint,
            issuedAt: payload.issuedAt,
            expiresAt: payload.expiresAt,
            signature: signature
        )

        state = .awaitingChallenge(payload: signedPayload)
    }

    public func currentPayload() -> PairingPayload? {
        switch state {
        case .awaitingChallenge(let payload), .displaying(let payload):
            return payload
        default:
            return nil
        }
    }

    @discardableResult
    public func handleChallenge(_ message: PairingChallengeMessage) async -> PairingAckMessage? {
        guard
            case .awaitingChallenge(let payload) = state,
            let configuration
        else { return nil }
        do {
            guard clock() <= payload.expiresAt else {
                throw PairingSessionError.payloadExpired
            }
            try verifyChallenge(message)
            let sharedKey = try await deriveSharedKey(initiatorPublicKey: message.initiatorPublicKey)
            let decrypted = try await decryptChallenge(message, sharedKey: sharedKey)
            try storeSharedKey(sharedKey, initiatorDeviceId: message.initiatorDeviceId)
            let ack = try await createAck(
                for: decrypted,
                challengeId: message.challengeId,
                sharedKey: sharedKey,
                responderDeviceName: configuration.deviceName
            )
            // Detect platform from device ID or default to "Unknown"
            let detectedPlatform = "Unknown"
            let device = PairedDevice(
                id: message.initiatorDeviceId,
                name: message.initiatorDeviceName,
                platform: detectedPlatform,
                lastSeen: clock(),
                isOnline: true
            )
            await MainActor.run {
                self.state = .completed(device: device)
                self.delegate?.pairingSession(self, didCompleteWith: device)
            }
            try persistAck(ack)
            return ack
        } catch {
            await MainActor.run {
                self.state = .failed(error.localizedDescription)
                self.delegate?.pairingSession(self, didFailWith: error)
            }
            return nil
        }
    }

    private func signPayload(_ payload: PairingPayload, signingKey: Curve25519.Signing.PrivateKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var payloadCopy = payload
        payloadCopy.signature = Data()
        let data = try encoder.encode(payloadCopy)
        return try signingKey.signature(for: data)
    }

    private func verifyChallenge(_ message: PairingChallengeMessage) throws {
        if lastChallenges.contains(message.challengeId) {
            throw PairingSessionError.duplicateChallenge
        }
        lastChallenges.append(message.challengeId)
        if lastChallenges.count > 32 {
            lastChallenges.removeFirst(lastChallenges.count - 32)
        }
    }

    private func deriveSharedKey(initiatorPublicKey: Data) async throws -> SymmetricKey {
        guard let ephemeralKey else {
            throw PairingSessionError.cryptoFailure
        }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: initiatorPublicKey)
        return try await cryptoService.deriveKey(privateKey: ephemeralKey, publicKey: publicKey)
    }

    private func decryptChallenge(_ message: PairingChallengeMessage, sharedKey: SymmetricKey) async throws -> PairingChallengePayload {
        let encrypted = (ciphertext: message.ciphertext, nonce: message.nonce, tag: message.tag)
        let plaintext: Data
        do {
            plaintext = try await cryptoService.decrypt(
                ciphertext: encrypted.ciphertext,
                key: sharedKey,
                nonce: encrypted.nonce,
                tag: encrypted.tag,
                aad: Data(message.initiatorDeviceId.utf8)
            )
        } catch {
            throw PairingSessionError.cryptoFailure
        }
        guard let payload = try? jsonDecoder.decode(PairingChallengePayload.self, from: plaintext) else {
            throw PairingSessionError.invalidChallengePayload
        }
        let now = clock()
        guard let configuration else { throw PairingSessionError.cryptoFailure }
        guard abs(payload.timestamp.timeIntervalSince(now)) <= configuration.challengeTolerance else {
            throw PairingSessionError.challengeWindowTooOld
        }
        return payload
    }

    private func createAck(
        for challenge: PairingChallengePayload,
        challengeId: UUID,
        sharedKey: SymmetricKey,
        responderDeviceName: String
    ) async throws -> PairingAckMessage {
        let hash = SHA256.hash(data: challenge.challenge)
        let payload = PairingAckPayload(
            responseHash: Data(hash),
            issuedAt: clock()
        )
        let data = try jsonEncoder.encode(payload)
        // Use pure UUID string (no prefix) for AAD
        let responderDeviceIdString = identity.uuidString.lowercased()
        let encrypted = try await cryptoService.encrypt(
            plaintext: data,
            key: sharedKey,
            aad: Data(responderDeviceIdString.utf8)
        )
        return PairingAckMessage(
            challengeId: challengeId,
            responderDeviceId: identity,
            responderDeviceName: responderDeviceName,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )
    }

    private func storeSharedKey(_ key: SymmetricKey, initiatorDeviceId: String) throws {
        try storeSharedKeyHandler(key, initiatorDeviceId)
    }
    


    private func persistAck(_ ack: PairingAckMessage) throws {
        // Placeholder for persisting ack or notifying Android via transport.
        _ = ack
    }
}
