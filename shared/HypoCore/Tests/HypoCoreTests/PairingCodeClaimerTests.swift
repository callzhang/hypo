import Testing
import Foundation
import CryptoKit
@testable import HypoCore

/// The two halves of pairing, against each other.
///
/// `PairingSession` shows a code and answers challenges; `PairingCodeClaimer`
/// claims a code and sends one. Only Android and the .NET harness could take
/// the claiming side until now, which is why two Swift clients could never
/// pair — both sat showing a code with nobody to claim it.
@Suite("Pairing round trip between two Swift clients")
@MainActor
struct PairingCodeClaimerTests {
    private func makeSession(
        storeSharedKey: @escaping @Sendable (SymmetricKey, String) -> Void = { _, _ in }
    ) throws -> (PairingSession, PairingPayload) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let session = PairingSession(
            identity: UUID(),
            signingKeyStore: FileBasedPairingSigningKeyStore(storageDirectory: tempDir),
            cryptoService: CryptoService(),
            storeSharedKey: storeSharedKey
        )
        try session.start(with: PairingSession.Configuration(
            service: "_hypo._tcp.local",
            port: 7010,
            relayHint: nil,
            deviceName: "Test Mac"
        ))
        let payload = try #require(session.currentPayload())
        return (session, payload)
    }

    /// The crypto, with no transport attached — which is the point: both the
    /// relay path and the LAN path go through this, so testing it here covers
    /// the contract for both.
    private func makeClaimer(deviceId: String = UUID().uuidString.lowercased()) -> PairingChallengeBuilder {
        PairingChallengeBuilder(deviceId: deviceId, deviceName: "Test iPhone")
    }

    @Test("the peer accepts our challenge and its ack verifies")
    func roundTripCompletes() async throws {
        let (session, payload) = try makeSession()
        let claimer = makeClaimer()

        let challenge = try await claimer.makeChallenge(peerPublicKey: payload.peerPublicKey)
        let ack = try #require(
            await session.handleChallenge(challenge.message),
            "the session rejected a challenge built by PairingCodeClaimer"
        )

        try await claimer.verifyAck(
            ack,
            answers: challenge.challengeBytes,
            sharedKey: challenge.sharedKey
        )
    }

    @Test("both sides end up holding the same key")
    func sharedKeysMatch() async throws {
        let stored = Locked<SymmetricKey?>(nil)
        let (session, payload) = try makeSession(storeSharedKey: { key, _ in
            stored.withLock { $0 = key }
        })
        let claimer = makeClaimer()

        let challenge = try await claimer.makeChallenge(peerPublicKey: payload.peerPublicKey)
        _ = try #require(await session.handleChallenge(challenge.message))

        let peerKey = try #require(stored.withLock { $0 })
        // Same bytes on both sides, or nothing either device sends afterwards
        // can be decrypted by the other.
        #expect(peerKey == challenge.sharedKey)
    }

    @Test("the session learns who we are")
    func peerIdentityCrossesOver() async throws {
        let ourId = UUID().uuidString.lowercased()
        let (session, payload) = try makeSession()
        let claimer = makeClaimer(deviceId: ourId)

        let challenge = try await claimer.makeChallenge(peerPublicKey: payload.peerPublicKey)
        _ = try #require(await session.handleChallenge(challenge.message))

        guard case .completed(let device) = session.state else {
            Issue.record("session did not complete, state was \(session.state)")
            return
        }
        #expect(device.id == ourId)
        #expect(device.name == "Test iPhone")
    }

    @Test("an ack answering a different challenge is rejected")
    func mismatchedAckIsRejected() async throws {
        let (session, payload) = try makeSession()
        let claimer = makeClaimer()

        let challenge = try await claimer.makeChallenge(peerPublicKey: payload.peerPublicKey)
        let ack = try #require(await session.handleChallenge(challenge.message))

        // Verifying against bytes we never sent must fail, or the check is
        // decorative and a replayed ack would sail through.
        await #expect(throws: PairingChallengeBuilder.Error.self) {
            try await claimer.verifyAck(
                ack,
                answers: Data(repeating: 0xAB, count: 32),
                sharedKey: challenge.sharedKey
            )
        }
    }
}
