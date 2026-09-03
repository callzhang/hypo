import Foundation
import Testing
@testable import HypoCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Pairing against bytes shaped the way Android actually writes them.
///
/// The existing pairing tests build their challenge with Swift's own encoder,
/// so both ends agree by construction and a difference in what Android emits
/// cannot show up. That is how the fractional-seconds bug survived: Android
/// writes `clock.instant().toString()`, which carries a fraction whenever it is
/// non-zero, and Swift's plain ISO-8601 reader returns nil for it. Pairing an
/// Android phone failed and nothing here noticed.
///
/// These fixtures are hand-built to Android's rules — kotlinx.serialization
/// with `encodeDefaults = false`, `@SerialName` snake_case keys, base64 via
/// `Base64.NO_WRAP`, timestamps via `Instant.toString()` — so a regression in
/// reading them fails here rather than on someone's phone.
/// Fixed so a challenge minted "now" lands inside the session's freshness
/// window. At file scope because the session's clock closure is Sendable and
/// cannot reach a main-actor member.
private let androidTestNow = Date(timeIntervalSince1970: 1_788_000_000)

@MainActor
@Suite("Android wire format")
struct AndroidWireFormatTests {
    /// The payload Android puts inside the ciphertext.
    ///
    /// `challenge` is a base64 string and `timestamp` is an Instant rendered to
    /// text; neither is a Swift type written by a Swift encoder.
    private func androidChallengePayload(secret: Data, timestamp: String) -> Data {
        let json = """
        {"challenge":"\(secret.base64EncodedString())","timestamp":"\(timestamp)"}
        """
        return Data(json.utf8)
    }

    /// The outer message, with the keys and casing Android's @SerialName gives
    /// it — and without `challenge_id`, which has a default and so is dropped
    /// by `encodeDefaults = false`.
    private func androidChallengeJSON(
        deviceId: String,
        deviceName: String,
        publicKey: Data,
        nonce: Data,
        ciphertext: Data,
        tag: Data
    ) -> Data {
        let json = """
        {"initiator_device_id":"\(deviceId)",\
        "initiator_device_name":"\(deviceName)",\
        "initiator_pub_key":"\(publicKey.base64EncodedString())",\
        "nonce":"\(nonce.base64EncodedString())",\
        "ciphertext":"\(ciphertext.base64EncodedString())",\
        "tag":"\(tag.base64EncodedString())"}
        """
        return Data(json.utf8)
    }

    private func signingKeyStore() -> FileBasedPairingSigningKeyStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return FileBasedPairingSigningKeyStore(storageDirectory: dir)
    }

    /// The session's own clock, so a challenge minted "now" lands inside the
    /// freshness window the session enforces.
    private var now: Date { androidTestNow }

    /// `now` rendered the way Instant.toString() renders it, with the given
    /// fraction spliced in — Instant emits nanoseconds, milliseconds, or none
    /// at all depending on the value.
    private func androidTimestamp(fraction: String) -> String {
        let whole = ISO8601DateFormatter().string(from: androidTestNow)
        guard !fraction.isEmpty else { return whole }
        return whole.replacingOccurrences(of: "Z", with: ".\(fraction)Z")
    }

    private func pair(timestamp: String) async throws -> (ack: PairingAckMessage?, reason: String) {
        let crypto = CryptoService()
        let session = PairingSession(
            identity: UUID(),
            signingKeyStore: signingKeyStore(),
            cryptoService: crypto,
            storeSharedKey: { _, _ in },
            clock: { androidTestNow }
        )
        try session.start(with: PairingSession.Configuration(
            service: "_hypo._tcp.local", port: 7010, relayHint: nil, deviceName: "iPhone"
        ))
        let payload = try #require(session.currentPayload())

        let androidKey = Curve25519.KeyAgreement.PrivateKey()
        let peerPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: payload.peerPublicKey)
        let shared = try await crypto.deriveKey(privateKey: androidKey, publicKey: peerPublic)

        let androidDeviceId = UUID().uuidString.lowercased()
        let encrypted = try await crypto.encrypt(
            plaintext: androidChallengePayload(secret: Data(repeating: 7, count: 32), timestamp: timestamp),
            key: shared,
            aad: Data(androidDeviceId.utf8)
        )
        let wire = androidChallengeJSON(
            deviceId: androidDeviceId,
            deviceName: "OPPO PLP110",
            publicKey: androidKey.publicKey.rawRepresentation,
            nonce: encrypted.nonce,
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )

        // Decoded from the bytes, not handed a Swift value. A field Android
        // names differently, or omits, fails here.
        let message = try JSONDecoder().decode(PairingChallengeMessage.self, from: wire)
        let ack = await session.handleChallenge(message)
        var reason = "no failure recorded"
        if case .failed(let message) = session.state { reason = message }
        return (ack, reason)
    }

    @Test("a challenge whose timestamp carries fractional seconds")
    func acceptsFractionalSeconds() async throws {
        // What Instant.toString() gives for a time with nanoseconds — the
        // common case, and the one that broke pairing with a real phone.
        let result = try await pair(timestamp: androidTimestamp(fraction: "123456789"))
        #expect(result.ack != nil, "\(result.reason)")
    }

    @Test("millisecond precision, which Instant also produces")
    func acceptsMilliseconds() async throws {
        let result = try await pair(timestamp: androidTimestamp(fraction: "123"))
        #expect(result.ack != nil, "\(result.reason)")
    }

    @Test("whole seconds, which Instant produces when the fraction is zero")
    func acceptsWholeSeconds() async throws {
        let result = try await pair(timestamp: androidTimestamp(fraction: ""))
        #expect(result.ack != nil, "\(result.reason)")
    }

    @Test("the message decodes without challenge_id, which Android omits")
    func decodesWithoutChallengeId() throws {
        // encodeDefaults = false drops it, since it has a default on Android.
        let wire = androidChallengeJSON(
            deviceId: UUID().uuidString.lowercased(),
            deviceName: "OPPO PLP110",
            publicKey: Data(repeating: 1, count: 32),
            nonce: Data(repeating: 2, count: 12),
            ciphertext: Data(repeating: 3, count: 16),
            tag: Data(repeating: 4, count: 16)
        )

        let message = try JSONDecoder().decode(PairingChallengeMessage.self, from: wire)

        #expect(message.initiatorDeviceName == "OPPO PLP110")
    }
}
