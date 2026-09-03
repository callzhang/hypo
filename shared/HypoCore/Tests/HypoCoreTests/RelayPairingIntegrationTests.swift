import Testing
import Foundation
import CryptoKit
@testable import HypoCore

/// Pairs two Swift clients through the live relay at hypo.fly.dev.
///
/// Disabled unless HYPO_RELAY_TESTS=1, because it needs the network and the
/// deployed backend: a suite that goes red when a server is down is a suite
/// people learn to ignore. Run it deliberately:
///
///     HYPO_RELAY_TESTS=1 swift test --filter RelayPairingIntegrationTests
///
/// What it covers that the offline round-trip test cannot: the relay's own
/// request and response shapes, and the fact that the claim/challenge/ack
/// endpoints hand the two sides to each other correctly.
@Suite(
    "Relay pairing, end to end",
    .enabled(if: ProcessInfo.processInfo.environment["HYPO_RELAY_TESTS"] == "1")
)
@MainActor
struct RelayPairingIntegrationTests {
    private var relayURL: URL { URL(string: "https://hypo.fly.dev")! }

    @Test("two Swift clients pair through the relay", .timeLimit(.minutes(2)))
    func pairsThroughRelay() async throws {
        let client = PairingRelayClient(baseURL: relayURL)

        // The showing side, exactly as the iOS and macOS pairing screens use it.
        let storedKey = Locked<SymmetricKey?>(nil)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = PairingSession(
            identity: UUID(),
            signingKeyStore: FileBasedPairingSigningKeyStore(storageDirectory: tempDir),
            cryptoService: CryptoService(),
            storeSharedKey: { key, _ in storedKey.withLock { $0 = key } }
        )
        try session.start(with: PairingSession.Configuration(
            service: "_hypo._tcp.local",
            port: 0,
            relayHint: relayURL,
            deviceName: "Showing Side"
        ))
        let payload = try #require(session.currentPayload())

        let code = try await client.createPairingCode(
            initiatorDeviceId: payload.peerDeviceId,
            initiatorDeviceName: "Showing Side",
            initiatorPublicKey: payload.peerPublicKey
        )

        // The showing side polls for a challenge; run that concurrently, the
        // way RemotePairingViewModel does.
        let pollTask = Task { () throws -> PairingAckMessage? in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for _ in 0..<40 {
                do {
                    let json = try await client.pollChallenge(
                        code: code.code,
                        initiatorDeviceId: payload.peerDeviceId
                    )
                    let message = try decoder.decode(
                        PairingChallengeMessage.self,
                        from: Data(json.utf8)
                    )
                    guard let ack = await session.handleChallenge(message) else { return nil }
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    try await client.submitAck(
                        code: code.code,
                        initiatorDeviceId: payload.peerDeviceId,
                        ackJSON: String(decoding: try encoder.encode(ack), as: UTF8.self)
                    )
                    return ack
                } catch PairingRelayClient.Error.challengeNotReady {
                    try? await Task.sleep(for: .milliseconds(750))
                }
            }
            return nil
        }

        // The claiming side — the half that did not exist in Swift until now.
        let claimer = PairingCodeClaimer(
            relayClient: client,
            deviceId: UUID().uuidString.lowercased(),
            deviceName: "Claiming Side"
        )
        let result = try await claimer.claim(code: code.code)

        let ack = try await pollTask.value
        #expect(ack != nil, "the showing side never produced an ack")

        #expect(result.peer.name == "Showing Side")
        // The whole point: both ends hold the same key, so anything either
        // sends afterwards can be decrypted by the other.
        let showingSideKey = try #require(storedKey.withLock { $0 })
        #expect(showingSideKey == result.sharedKey)
    }
}
