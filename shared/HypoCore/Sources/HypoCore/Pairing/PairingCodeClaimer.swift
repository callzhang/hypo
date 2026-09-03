import Foundation
import CryptoKit

/// Claims a pairing code that another device is showing, over the relay.
///
/// The counterpart to `PairingSession`, which shows a code and answers
/// challenges. Until this existed only Android and the .NET harness could take
/// this side, so two Swift clients could never pair: both would sit showing a
/// code with nobody to claim it.
///
/// Naming is unavoidably confusing because the layers disagree. The relay calls
/// the code's owner the "initiator" and the claimer the "responder";
/// `PairingChallengeMessage` uses those words the other way round. This type
/// speaks in terms of "us" and "the peer" to stay out of it.
public struct PairingCodeClaimer: Sendable {
    public struct Result: Sendable {
        public let peer: PairedDevice
        public let sharedKey: SymmetricKey
    }

    public enum Error: Swift.Error, LocalizedError {
        case ackNeverArrived

        public var errorDescription: String? {
            switch self {
            case .ackNeverArrived:
                return "The other device did not answer the pairing challenge"
            }
        }
    }

    private let relayClient: PairingRelayClient
    private let builder: PairingChallengeBuilder
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

    /// Claims `code`, sends a challenge, and waits for the answer.
    ///
    /// The other device answers when its own poll loop notices the challenge,
    /// which is on its own timer, so this cannot be instant.
    public func claim(
        code: String,
        pollInterval: Duration = .milliseconds(1500),
        timeout: Duration = .seconds(60)
    ) async throws -> Result {
        // One ephemeral key for both calls. The peer derives against the key
        // carried in the challenge, so announcing a different one in the claim
        // would leave the relay holding a key nobody uses.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()

        let claimed = try await relayClient.claimPairingCode(
            code: code,
            responderDeviceId: deviceId,
            responderDeviceName: deviceName,
            responderPublicKey: ephemeral.publicKey.rawRepresentation
        )
        let challenge = try await builder.makeChallenge(
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

        let ack = try await waitForAck(code: code, pollInterval: pollInterval, timeout: timeout)
        try await builder.verifyAck(
            ack,
            answers: challenge.challengeBytes,
            sharedKey: challenge.sharedKey
        )

        let peer = PairedDevice(
            id: ack.responderDeviceId.uuidString.lowercased(),
            name: ack.responderDeviceName,
            platform: "Unknown",
            lastSeen: clock(),
            isOnline: true
        )
        return Result(peer: peer, sharedKey: challenge.sharedKey)
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
}
