import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import HypoCore

struct SyncEngineTests {
    @Test
    func testTransmitEncryptsPayloadAndDecodeRecoversPlaintext() async throws {
        let sharedKey = SymmetricKey(size: .bits256)
        let senderProvider = InMemoryDeviceKeyProvider()
        await senderProvider.setKey(sharedKey, for: "android-device")

        let transport = RecordingTransport()
        let senderEngine = SyncEngine(
            transport: transport,
            keyProvider: senderProvider,
            localDeviceId: "mac-device"
        )

        await senderEngine.establishConnection()

        let clipboardEntry = ClipboardEntry(
            deviceId: "mac-device",
            originPlatform: .macOS,
            originDeviceName: "Test Mac",
            content: .text("Hello world")
        )
        let payload = ClipboardPayload(
            contentType: .text,
            data: Data("Hello world".utf8)
        )

        try await senderEngine.transmit(
            entry: clipboardEntry,
            payload: payload,
            targetDeviceId: "android-device"
        )

        let envelope = try #require(transport.sentEnvelopes.first)

        #expect(envelope.payload.deviceId == "mac-device")
        #expect(envelope.payload.target == "android-device")
        #expect(envelope.payload.encryption.algorithm == "AES-256-GCM")
        #expect(envelope.payload.ciphertext != payload.data)

        let receiverProvider = InMemoryDeviceKeyProvider()
        await receiverProvider.setKey(sharedKey, for: "mac-device")
        let receiverEngine = SyncEngine(
            transport: NoopTransport(),
            keyProvider: receiverProvider,
            localDeviceId: "android-device"
        )

        let encoded = try TransportFrameCodec().encode(envelope)
        let decoded = try await receiverEngine.decode(encoded)
        #expect(decoded.contentType == payload.contentType)
        #expect(decoded.data == payload.data)
    }

    @Test
    func testDecodeThrowsWhenKeyMissing() async {
        let engine = SyncEngine(
            transport: NoopTransport(),
            keyProvider: InMemoryDeviceKeyProvider(),
            localDeviceId: "android-device"
        )

        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: .init(
                contentType: .text,
                ciphertext: Data([0, 1, 2]),
                deviceId: "mac-device",
                target: "android-device",
                encryption: .init(nonce: Data(repeating: 0, count: 12), tag: Data(repeating: 0, count: 16))
            )
        )

        let encoded = try! TransportFrameCodec().encode(envelope)

        do {
            _ = try await engine.decode(encoded)
            #expect(Bool(false))
        } catch {
            guard let providerError = error as? DeviceKeyProviderError else {
                #expect(Bool(false))
                return
            }
            switch providerError {
            case .missingKey(let deviceId):
                #expect(deviceId == "mac-device")
            }
        }
    }
    @Test
    func testTransmitThrowsWhenNotConnected() async {
        let engine = SyncEngine(
            transport: NoopTransport(),
            keyProvider: InMemoryDeviceKeyProvider(),
            localDeviceId: "mac-device"
        )
        // Ensure state is idle
        let payload = ClipboardPayload(contentType: .text, data: Data())
        let entry = ClipboardEntry(
            deviceId: "mac-device",
            originPlatform: .macOS,
            originDeviceName: "Mac",
            content: .text("test")
        )
        
        await #expect(throws: Error.self) {
            try await engine.transmit(entry: entry, payload: payload, targetDeviceId: "target")
        }
    }
    
    @Test
    func testTransmitUsingPlainTextMode() async throws {
        // Use separate suite to avoid polluting standard defaults
        let defaults = UserDefaults(suiteName: "SyncEngineTests")!
        defaults.set(true, forKey: "plain_text_mode_enabled")
        defer { defaults.removePersistentDomain(forName: "SyncEngineTests") }
        
        let transport = RecordingTransport()
        let engine = SyncEngine(
            transport: transport,
            keyProvider: InMemoryDeviceKeyProvider(),
            localDeviceId: "mac-device",
            defaults: defaults
        )
        await engine.establishConnection()
        
        let payload = ClipboardPayload(contentType: .text, data: Data("plain".utf8))
        let entry = ClipboardEntry(
            deviceId: "mac-device", 
            originPlatform: .macOS, 
            originDeviceName: "Mac", 
            content: .text("plain")
        )
        
        try await engine.transmit(entry: entry, payload: payload, targetDeviceId: "target")
        
        let envelope = try #require(transport.sentEnvelopes.first)
        // Nonce and tag should be empty for plain text mode
        #expect(envelope.payload.encryption.nonce.isEmpty)
        #expect(envelope.payload.encryption.tag.isEmpty)
        
        // Also verify receipt handling in plain text mode
        let receiverEngine = SyncEngine(
             transport: NoopTransport(),
             keyProvider: InMemoryDeviceKeyProvider(),
             localDeviceId: "target"
        )
        
        // Encode the envelope we just sent
        let encoded = try TransportFrameCodec().encode(envelope)
        let decoded = try await receiverEngine.decode(encoded)
        #expect(decoded.data == payload.data)
    }
}

@Suite("Reporting what could not be decrypted")
struct ReceiveFailureReportTests {
    /// A device that takes the bytes and cannot decrypt them looks exactly like
    /// a successful sync from the relay, which sees only that the frame reached
    /// a connected socket. Reporting it is what puts the failure in the server
    /// log; nothing waits for the report and nothing is retried.
    @Test
    func decryptionFailureIsReported() async throws {
        let sender = "mac-device"
        let transport = RecordingTransport()
        // A key is present, so this gets past the key lookup and fails where it
        // should: on the ciphertext itself.
        let engine = SyncEngine(
            transport: transport,
            keyProvider: InMemoryDeviceKeyProvider(storage: [sender: SymmetricKey(size: .bits256)]),
            localDeviceId: "android-device"
        )

        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: .init(
                contentType: .text,
                ciphertext: Data(repeating: 0xAB, count: 32),
                deviceId: sender,
                target: "android-device",
                encryption: .init(
                    nonce: Data(repeating: 0x01, count: 12),
                    tag: Data(repeating: 0x02, count: 16)
                )
            )
        )
        let framed = try TransportFrameCodec().encode(envelope)

        do {
            _ = try await engine.decode(framed)
            #expect(Bool(false), "this ciphertext should not have opened")
        } catch {
            // expected
        }

        #expect(transport.receiveFailures.count == 1, "the failure was not reported")
        #expect(transport.receiveFailures.first?.0 == envelope.id)
        #expect(transport.receiveFailures.first?.1.contains("decryption failed") == true)
    }
}

private final class RecordingTransport: SyncTransport, @unchecked Sendable {
    private(set) var sentEnvelopes: [SyncEnvelope] = []
    private(set) var connectCallCount = 0
    private(set) var receiveFailures: [(UUID, String)] = []

    func reportReceiveFailure(messageId: UUID, reason: String) async {
        receiveFailures.append((messageId, reason))
    }

    func connect() async throws {
        connectCallCount += 1
    }

    func send(_ envelope: SyncEnvelope) async throws {
        sentEnvelopes.append(envelope)
    }

    func disconnect() async {}
}

private struct NoopTransport: SyncTransport {
    func connect() async throws {}
    func send(_ envelope: SyncEnvelope) async throws {}
    func disconnect() async {}
}
