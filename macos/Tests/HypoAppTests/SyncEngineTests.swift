import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import HypoApp

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
            #expect(false)
        } catch {
            guard let providerError = error as? DeviceKeyProviderError else {
                #expect(false)
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

private final class RecordingTransport: SyncTransport, @unchecked Sendable {
    private(set) var sentEnvelopes: [SyncEnvelope] = []
    private(set) var connectCallCount = 0

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
