import Foundation
import Testing
@testable import HypoCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@MainActor
struct LanPairingInitiatorTests {
    /// The initiator and the responder are the two halves of the same handshake, so
    /// running them against each other is the test that matters: it proves a Mac can
    /// start a pairing the same way an Android or Windows peer does.
    @Test
    func testPairsWithResponderSession() async throws {
        let responderId = UUID()
        let responderAgreementKey = Curve25519.KeyAgreement.PrivateKey()
        let responderStored = Locked<[String: SymmetricKey]>([:])
        let session = PairingSession(
            identity: responderId,
            signingKeyStore: makeSigningKeyStore(),
            storeSharedKey: { key, deviceId in
                responderStored.withLock { $0[deviceId] = key }
            }
        )
        try session.start(
            with: PairingSession.Configuration(
                service: "_hypo._tcp.local",
                port: 7010,
                relayHint: nil,
                deviceName: "Responder Mac"
            ),
            keyAgreementKey: responderAgreementKey
        )

        let peer = makePeer(
            deviceId: responderId.uuidString.lowercased(),
            publicKey: responderAgreementKey.publicKey.rawRepresentation.base64EncodedString()
        )

        let initiatorStored = Locked<[String: SymmetricKey]>([:])
        let initiatorId = UUID()
        let initiator = LanPairingInitiator(
            identity: StubIdentity(deviceId: initiatorId, deviceName: "Initiator Mac"),
            storeSharedKey: { key, deviceId in
                initiatorStored.withLock { $0[deviceId] = key }
            },
            exchange: { challenge, _, _ in
                guard let ack = await session.handleChallenge(challenge) else {
                    throw LanPairingError.noReply
                }
                return ack
            }
        )

        let device = try await initiator.pair(with: peer)

        #expect(device.id == responderId.uuidString.lowercased())
        #expect(device.name == "Responder Mac")
        #expect(device.bonjourHost == "192.168.1.42")
        #expect(device.bonjourPort == 7010)

        // Both sides must end up holding the same key, or nothing they send each
        // other afterwards decrypts.
        let initiatorKey = initiatorStored.withLock { $0[responderId.uuidString.lowercased()] }
        let responderKey = responderStored.withLock { $0[initiatorId.uuidString.lowercased()] }
        #expect(initiatorKey != nil)
        #expect(initiatorKey == responderKey)
    }

    @Test
    func testRejectsPeerWithoutAdvertisedKey() async throws {
        let initiator = LanPairingInitiator(
            identity: StubIdentity(deviceId: UUID(), deviceName: "Initiator Mac"),
            storeSharedKey: { _, _ in },
            exchange: { _, _, _ in throw LanPairingError.noReply }
        )
        let peer = makePeer(deviceId: UUID().uuidString.lowercased(), publicKey: nil)

        await #expect(throws: LanPairingError.peerAdvertisesNoKey) {
            _ = try await initiator.pair(with: peer)
        }
    }

    /// A responder that answers with a key of its own is answering a different
    /// exchange, and its ack must not be taken as proof of anything.
    @Test
    func testRejectsAckFromADifferentExchange() async throws {
        let responderId = UUID()
        let advertisedKey = Curve25519.KeyAgreement.PrivateKey()
        let impostorKey = Curve25519.KeyAgreement.PrivateKey()
        let session = PairingSession(
            identity: responderId,
            signingKeyStore: makeSigningKeyStore(),
            storeSharedKey: { _, _ in }
        )
        try session.start(
            with: PairingSession.Configuration(
                service: "_hypo._tcp.local",
                port: 7010,
                relayHint: nil,
                deviceName: "Responder Mac"
            ),
            keyAgreementKey: impostorKey
        )

        let peer = makePeer(
            deviceId: responderId.uuidString.lowercased(),
            publicKey: advertisedKey.publicKey.rawRepresentation.base64EncodedString()
        )
        let initiator = LanPairingInitiator(
            identity: StubIdentity(deviceId: UUID(), deviceName: "Initiator Mac"),
            storeSharedKey: { _, _ in
                Issue.record("A key from an unverified ack must never be stored")
            },
            exchange: { challenge, _, _ in
                guard let ack = await session.handleChallenge(challenge) else {
                    throw LanPairingError.noReply
                }
                return ack
            }
        )

        await #expect(throws: (any Error).self) {
            _ = try await initiator.pair(with: peer)
        }
    }

    // MARK: - Helpers

    private func makePeer(deviceId: String, publicKey: String?) -> DiscoveredPeer {
        var metadata = ["device_id": deviceId]
        if let publicKey {
            metadata["pub_key"] = publicKey
        }
        return DiscoveredPeer(
            serviceName: "responder._hypo._tcp.local",
            endpoint: LanEndpoint(
                host: "192.168.1.42",
                port: 7010,
                deviceId: deviceId,
                deviceName: "Responder Mac",
                fingerprint: nil,
                metadata: metadata
            ),
            lastSeen: Date()
        )
    }

    private func makeSigningKeyStore() -> FileBasedPairingSigningKeyStore {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return FileBasedPairingSigningKeyStore(storageDirectory: tempDir)
    }
}

private struct StubIdentity: DeviceIdentityProviding {
    let deviceId: UUID
    let deviceName: String
    var deviceIdString: String { deviceId.uuidString.lowercased() }
    var platform: DevicePlatform { .macOS }
}
