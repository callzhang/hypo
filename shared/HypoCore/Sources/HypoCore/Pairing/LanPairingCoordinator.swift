import Foundation
import CryptoKit

/// Pairs with a device already visible on this network, without a code.
///
/// The counterpart to claiming a relay code: same challenge, same ack, carried
/// over a web socket to the peer instead of through an HTTP round trip. Typing
/// six digits should be the fallback for devices that cannot see each other,
/// not the only way to pair with one that is right there.
public actor LanPairingCoordinator {
    public struct Result: Sendable {
        public let peer: PairedDevice
        public let sharedKey: SymmetricKey
    }

    public enum Error: Swift.Error, LocalizedError {
        case peerAdvertisesNoKey
        /// Carries whatever did arrive, if anything: "did not answer" and
        /// "answered with something unreadable" need different fixes and look
        /// identical without this.
        case noAnswer(sawInstead: String?)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .peerAdvertisesNoKey:
                return "That device is not advertising a key to pair with"
            case .noAnswer(let seen):
                guard let seen else { return "That device did not answer" }
                return "Could not read the answer from that device: \(seen)"
            case .timedOut:
                return "That device did not respond in time"
            }
        }
    }

    private let builder: PairingChallengeBuilder
    private let deviceId: String
    private let deviceName: String
    private let clock: @Sendable () -> Date

    public init(
        cryptoService: CryptoService = CryptoService(),
        deviceId: String,
        deviceName: String,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.deviceId = deviceId.lowercased()
        self.deviceName = deviceName
        self.clock = clock
        self.builder = PairingChallengeBuilder(
            cryptoService: cryptoService,
            deviceId: deviceId,
            deviceName: deviceName,
            clock: clock
        )
    }

    /// Bounds the whole exchange, not just the wait for an answer.
    ///
    /// Dialling can hang indefinitely — a phone that advertises but does not
    /// accept leaves connect() waiting forever — and the screen then sits on
    /// "Pairing with …" with nothing to report and no way back.
    public func pair(with peer: DiscoveredPeer, timeout: Duration = .seconds(30)) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask { try await self.attemptPair(with: peer, ackTimeout: timeout) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Error.timedOut
            }
            guard let first = try await group.next() else { throw Error.timedOut }
            group.cancelAll()
            return first
        }
    }

    private func attemptPair(with peer: DiscoveredPeer, ackTimeout timeout: Duration) async throws -> Result {
        guard let advertised = peer.endpoint.metadata["pub_key"],
              let peerPublicKey = Data(base64Encoded: advertised) else {
            throw Error.peerAdvertisesNoKey
        }

        let transport = WebSocketTransport(
            configuration: WebSocketConfiguration(
                url: URL(string: "ws://\(peer.endpoint.host):\(peer.endpoint.port)")!,
                pinnedFingerprint: nil,
                headers: [
                    "X-Device-Id": deviceId,
                    "X-Device-Platform": DeviceIdentity().platform.rawValue
                ],
                idleTimeout: 60,
                environment: "lan",
                roundTripTimeout: 30
            ),
            frameCodec: TransportFrameCodec(),
            metricsRecorder: NullTransportMetricsRecorder(),
            analytics: NoopTransportAnalytics()
        )

        let inbox = AckInbox()
        transport.setOnIncomingMessage { data, _ in
            await inbox.offer(data)
        }

        try await transport.connect()
        defer { Task { await transport.disconnect() } }

        let challenge = try await builder.makeChallenge(peerPublicKey: peerPublicKey)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await transport.sendRaw(try encoder.encode(challenge.message))

        guard let ack = await inbox.waitForAck(timeout: timeout) else {
            throw Error.noAnswer(sawInstead: await inbox.unreadable)
        }
        try await builder.verifyAck(
            ack,
            answers: challenge.challengeBytes,
            sharedKey: challenge.sharedKey
        )

        let paired = PairedDevice(
            id: ack.responderDeviceId.uuidString.lowercased(),
            name: ack.responderDeviceName,
            platform: "Unknown",
            lastSeen: clock(),
            isOnline: true,
            serviceName: peer.serviceName,
            bonjourHost: peer.endpoint.host,
            bonjourPort: peer.endpoint.port,
            fingerprint: peer.endpoint.fingerprint
        )
        return Result(peer: paired, sharedKey: challenge.sharedKey)
    }
}

/// Holds whatever arrives on the pairing connection until an ack shows up.
///
/// Anything else on that socket is ignored rather than treated as a failure:
/// a peer may be mid-conversation about other things when we dial it.
private actor AckInbox {
    private var ack: PairingAckMessage?
    /// The last thing that arrived and could not be read as an ack, so a
    /// timeout can say whether nothing came or something unusable did.
    private(set) var unreadable: String?

    func offer(_ data: Data) {
        guard ack == nil else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            ack = try decoder.decode(PairingAckMessage.self, from: data)
        } catch {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
            unreadable = "\(error.localizedDescription) — \(preview)"
        }
    }

    func waitForAck(timeout: Duration) async -> PairingAckMessage? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let ack { return ack }
            try? await clock.sleep(for: .milliseconds(200))
        }
        return ack
    }
}
