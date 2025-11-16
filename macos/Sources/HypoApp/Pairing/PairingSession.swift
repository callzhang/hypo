import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
public typealias PairingQRCodeImage = CGImage
#else
public typealias PairingQRCodeImage = AnyObject
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
            return "QR signature verification failed"
        case .payloadExpired:
            return "Pairing QR code expired"
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
        public var qrValidity: TimeInterval
        public var challengeTolerance: TimeInterval
        public var deviceName: String

        public init(
            service: String,
            port: Int,
            relayHint: URL?,
            qrValidity: TimeInterval = 300,
            challengeTolerance: TimeInterval = 30,
            deviceName: String
        ) {
            self.service = service
            self.port = port
            self.relayHint = relayHint
            self.qrValidity = qrValidity
            self.challengeTolerance = challengeTolerance
            self.deviceName = deviceName
        }
    }

    public enum State {
        case idle
        case displaying(payload: PairingPayload, image: PairingQRCodeImage?)
        case awaitingChallenge(payload: PairingPayload, image: PairingQRCodeImage?)
        case completed(device: PairedDevice)
        case failed(String)
    }

    private let identity: UUID
    private let signingKeyStore: PairingSigningKeyStore
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
        signingKeyStore: PairingSigningKeyStore = PairingSigningKeyStore(),
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
        let expiresAt = issuedAt.addingTimeInterval(configuration.qrValidity)
        let payload = PairingPayload(
            macDeviceId: identity,
            macPublicKey: agreementKey.publicKey.rawRepresentation,
            macSigningPublicKey: signingKey.publicKey.rawRepresentation,
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
            macDeviceId: payload.macDeviceId,
            macPublicKey: payload.macPublicKey,
            macSigningPublicKey: payload.macSigningPublicKey,
            service: payload.service,
            port: payload.port,
            relayHint: payload.relayHint,
            issuedAt: payload.issuedAt,
            expiresAt: payload.expiresAt,
            signature: signature
        )

        let qrImage = generateQRCodeImage(from: signedPayload)
        state = .awaitingChallenge(payload: signedPayload, image: qrImage)
    }

    public func qrPayloadJSON() throws -> String {
        guard case .awaitingChallenge(let payload, _) = state else {
            throw PairingSessionError.payloadExpired
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    public func qrCodeImage() -> PairingQRCodeImage? {
        switch state {
        case .awaitingChallenge(_, let image), .displaying(_, let image):
            return image
        default:
            return nil
        }
    }

    public func currentPayload() -> PairingPayload? {
        switch state {
        case .awaitingChallenge(let payload, _), .displaying(let payload, _):
            return payload
        default:
            return nil
        }
    }

    @discardableResult
    public func handleChallenge(_ message: PairingChallengeMessage) async -> PairingAckMessage? {
        guard
            case .awaitingChallenge(let payload, _) = state,
            let configuration
        else { return nil }
        do {
            guard clock() <= payload.expiresAt else {
                throw PairingSessionError.payloadExpired
            }
            try verifyChallenge(message)
            let sharedKey = try await deriveSharedKey(androidPublicKey: message.androidPublicKey)
            let decrypted = try await decryptChallenge(message, sharedKey: sharedKey)
            try storeSharedKey(sharedKey, androidDeviceId: message.androidDeviceId)
            let ack = try await createAck(
                for: decrypted,
                challengeId: message.challengeId,
                sharedKey: sharedKey,
                macDeviceName: configuration.deviceName
            )
            let deviceUUID = UUID(uuidString: message.androidDeviceId) ?? UUID()
            let device = PairedDevice(
                id: deviceUUID,
                name: message.androidDeviceName,
                platform: "Android",
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

    private func generateQRCodeImage(from payload: PairingPayload) -> PairingQRCodeImage? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        #if canImport(CoreImage)
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(data, forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            if let output = filter.outputImage {
                let transform = CGAffineTransform(scaleX: 6, y: 6)
                return output.transformed(by: transform).toCGImage()
            }
        }
        #endif
        return nil
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

    private func deriveSharedKey(androidPublicKey: Data) async throws -> SymmetricKey {
        guard let ephemeralKey else {
            throw PairingSessionError.cryptoFailure
        }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: androidPublicKey)
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
                aad: Data(message.androidDeviceId.utf8)
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
        macDeviceName: String
    ) async throws -> PairingAckMessage {
        let hash = SHA256.hash(data: challenge.challenge)
        let payload = PairingAckPayload(
            responseHash: Data(hash),
            issuedAt: clock()
        )
        let data = try jsonEncoder.encode(payload)
        // Use lowercase UUID string to match Android's expectation (ack.macDeviceId.toByteArray())
        let macDeviceIdString = identity.uuidString.lowercased()
        let encrypted = try await cryptoService.encrypt(
            plaintext: data,
            key: sharedKey,
            aad: Data(macDeviceIdString.utf8)
        )
        return PairingAckMessage(
            challengeId: challengeId,
            macDeviceId: identity,
            macDeviceName: macDeviceName,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )
    }

    private func storeSharedKey(_ key: SymmetricKey, androidDeviceId: String) throws {
        try storeSharedKeyHandler(key, androidDeviceId)
    }

    private func persistAck(_ ack: PairingAckMessage) throws {
        // Placeholder for persisting ack or notifying Android via transport.
        _ = ack
    }
}

#if canImport(CoreImage)
import CoreImage

private extension CIImage {
    func toCGImage() -> CGImage? {
        let context = CIContext(options: nil)
        return context.createCGImage(self, from: extent)
    }
}
#endif
