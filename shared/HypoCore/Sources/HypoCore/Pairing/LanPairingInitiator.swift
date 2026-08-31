import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a LAN pairing attempt ended the way it did.
public enum LanPairingError: LocalizedError, Equatable {
    /// The peer's Bonjour record carries no agreement key, so there is nothing to pair against.
    case peerAdvertisesNoKey
    case invalidPeerKey
    case unreachable(String)
    /// Connected, and nothing we could read as an acknowledgement arrived in time.
    case noReply
    case ackRejected(String)
    /// The device that answered is not the one the Bonjour record claimed.
    case identityMismatch

    public var errorDescription: String? {
        switch self {
        case .peerAdvertisesNoKey:
            return "This device does not advertise a pairing key. Update Hypo on it and try again."
        case .invalidPeerKey:
            return "This device advertises a pairing key we cannot read."
        case .unreachable(let detail):
            return "Could not reach the device: \(detail)"
        case .noReply:
            return "The device did not answer. Make sure Hypo is running on it and both devices are on the same network."
        case .ackRejected(let reason):
            return "The device's reply did not verify: \(reason)"
        case .identityMismatch:
            return "The device that answered is not the one that was advertised."
        }
    }
}

/// Runs the initiator half of LAN pairing: the side that picks a device off the
/// Bonjour list and opens the handshake. `PairingSession` is the responder half,
/// which is all a Mac could do until now — it could be paired *with*, but could
/// not start a pairing itself.
///
/// The exchange is deliberately unframed: the challenge and its acknowledgement
/// travel as bare JSON in text frames, because every peer detects a challenge by
/// looking for `initiator_device_id` in the body, and length-prefixing would bury
/// that inside base64. This matches the Android and Windows initiators.
@MainActor
public final class LanPairingInitiator {
    /// The wire step: hand a challenge to a peer and come back with its acknowledgement.
    /// Injectable so the handshake can be exercised without a socket.
    public typealias Exchange = @Sendable (PairingChallengeMessage, DiscoveredPeer, TimeInterval) async throws -> PairingAckMessage

    private let identity: DeviceIdentityProviding
    private let cryptoService: CryptoService
    private let storeSharedKeyHandler: @Sendable (SymmetricKey, String) throws -> Void
    private let clock: @Sendable () -> Date
    private let session: URLSession
    private let exchangeOverride: Exchange?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = HypoLogger(category: "LanPairingInitiator")

    /// How far the responder's clock may sit from ours before we distrust the ack.
    private let ackTolerance: TimeInterval = 300

    public init(
        identity: DeviceIdentityProviding = DeviceIdentity(),
        cryptoService: CryptoService = CryptoService(),
        deviceKeyProvider: KeychainDeviceKeyProvider = KeychainDeviceKeyProvider(),
        storeSharedKey: (@Sendable (SymmetricKey, String) throws -> Void)? = nil,
        session: URLSession = URLSession(configuration: .ephemeral),
        exchange: Exchange? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.exchangeOverride = exchange
        self.identity = identity
        self.cryptoService = cryptoService
        if let storeSharedKey {
            self.storeSharedKeyHandler = storeSharedKey
        } else {
            self.storeSharedKeyHandler = { key, deviceId in
                try deviceKeyProvider.store(key: key, for: deviceId)
            }
        }
        self.session = session
        self.clock = clock

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Pairs with a peer found on the LAN and stores the resulting key.
    ///
    /// - Returns: the peer as a paired device, named by the identity it proved in
    ///   its acknowledgement rather than by its Bonjour service name.
    public func pair(with peer: DiscoveredPeer, timeout: TimeInterval = 30) async throws -> PairedDevice {
        guard
            let advertisedKey = peer.endpoint.metadata["pub_key"],
            !advertisedKey.isEmpty,
            let publicKeyData = Data(base64Encoded: advertisedKey)
        else {
            throw LanPairingError.peerAdvertisesNoKey
        }
        guard let peerPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyData) else {
            throw LanPairingError.invalidPeerKey
        }

        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedKey = try await cryptoService.deriveKey(privateKey: agreementKey, publicKey: peerPublicKey)

        // The secret the responder has to hand back hashed, which is what proves it
        // decrypted our challenge rather than replaying a well-formed message.
        let challengeSecret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let challengeId = UUID()
        let challengePayload = PairingChallengePayload(challenge: challengeSecret, timestamp: clock())
        let sealed = try await cryptoService.encrypt(
            plaintext: try encoder.encode(challengePayload),
            key: sharedKey,
            aad: Data(identity.deviceIdString.utf8)
        )
        let challenge = PairingChallengeMessage(
            challengeId: challengeId,
            initiatorDeviceId: identity.deviceIdString,
            initiatorDeviceName: identity.deviceName,
            initiatorPublicKey: agreementKey.publicKey.rawRepresentation,
            nonce: sealed.nonce,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )

        logger.info("🤝 [LanPairingInitiator] Pairing with \(peer.serviceName) at \(peer.endpoint.host):\(peer.endpoint.port)")
        let ack: PairingAckMessage
        if let exchangeOverride {
            ack = try await exchangeOverride(challenge, peer, timeout)
        } else {
            ack = try await exchange(challenge, with: peer, timeout: timeout)
        }

        guard ack.challengeId == challengeId else {
            throw LanPairingError.ackRejected("challenge mismatch")
        }

        let responderId = ack.responderDeviceId.uuidString.lowercased()
        if let advertisedId = peer.endpoint.metadata["device_id"],
           !advertisedId.isEmpty,
           advertisedId.lowercased() != responderId {
            throw LanPairingError.identityMismatch
        }

        let plaintext: Data
        do {
            plaintext = try await cryptoService.decrypt(
                ciphertext: ack.ciphertext,
                key: sharedKey,
                nonce: ack.nonce,
                tag: ack.tag,
                aad: Data(responderId.utf8)
            )
        } catch {
            throw LanPairingError.ackRejected("could not decrypt")
        }
        guard let ackPayload = try? decoder.decode(PairingAckPayload.self, from: plaintext) else {
            throw LanPairingError.ackRejected("unreadable payload")
        }

        let expectedHash = Data(SHA256.hash(data: challengeSecret))
        guard constantTimeEquals(ackPayload.responseHash, expectedHash) else {
            throw LanPairingError.ackRejected("wrong challenge response")
        }
        guard abs(ackPayload.issuedAt.timeIntervalSince(clock())) <= ackTolerance else {
            throw LanPairingError.ackRejected("timestamp outside the allowed window")
        }

        try storeSharedKeyHandler(sharedKey, responderId)
        logger.info("✅ [LanPairingInitiator] Paired with \(ack.responderDeviceName) (\(responderId.prefix(8)))")

        return PairedDevice(
            id: responderId,
            name: ack.responderDeviceName,
            platform: peer.endpoint.metadata["platform"] ?? "Unknown",
            lastSeen: clock(),
            isOnline: true,
            serviceName: peer.serviceName,
            bonjourHost: peer.endpoint.host,
            bonjourPort: peer.endpoint.port,
            fingerprint: peer.endpoint.fingerprint
        )
    }

    // MARK: - Wire

    private func exchange(
        _ challenge: PairingChallengeMessage,
        with peer: DiscoveredPeer,
        timeout: TimeInterval
    ) async throws -> PairingAckMessage {
        // Root path with a device_id query and the header both set: the same shape
        // the shipping Windows client uses, which every peer server already accepts.
        var components = URLComponents()
        components.scheme = "ws"
        components.host = peer.endpoint.host
        components.port = peer.endpoint.port
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "device_id", value: identity.deviceIdString)]
        guard let url = components.url else {
            throw LanPairingError.unreachable("bad address \(peer.endpoint.host):\(peer.endpoint.port)")
        }

        var request = URLRequest(url: url)
        request.setValue(identity.deviceIdString, forHTTPHeaderField: "X-Device-Id")
        request.setValue(identity.platform.rawValue, forHTTPHeaderField: "X-Device-Platform")

        // Typed explicitly: HypoCore also puts a `WebSocketTasking`-returning
        // `webSocketTask(with:)` on URLSession, which makes the bare call ambiguous.
        let task: URLSessionWebSocketTask = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let challengeJSON = String(decoding: try encoder.encode(challenge), as: UTF8.self)
        do {
            try await task.send(.string(challengeJSON))
        } catch {
            throw LanPairingError.unreachable(error.localizedDescription)
        }

        return try await withTimeout(seconds: timeout) { [decoder] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    throw LanPairingError.unreachable(error.localizedDescription)
                }
                let data: Data?
                switch message {
                case .string(let text):
                    data = text.data(using: .utf8)
                case .data(let raw):
                    data = raw
                @unknown default:
                    data = nil
                }
                // A message we cannot read is not the one we are waiting for; the
                // peer may greet us before answering. Keep reading until the clock runs out.
                if let data, let ack = try? decoder.decode(PairingAckMessage.self, from: data) {
                    return ack
                }
            }
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LanPairingError.noReply
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw LanPairingError.noReply
            }
            return result
        }
    }

    private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
