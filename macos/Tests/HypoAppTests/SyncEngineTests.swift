import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import HypoApp

final class SyncEngineTests: XCTestCase {
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
            originDeviceId: "mac-device",
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

        guard let envelope = transport.sentEnvelopes.first else {
            XCTFail("expected envelope to be sent")
            return
        }

        XCTAssertEqual(envelope.payload.deviceId, "mac-device")
        XCTAssertEqual(envelope.payload.target, "android-device")
        XCTAssertEqual(envelope.payload.encryption.algorithm, "AES-256-GCM")
        XCTAssertNotEqual(envelope.payload.ciphertext, payload.data)

        let receiverProvider = InMemoryDeviceKeyProvider()
        await receiverProvider.setKey(sharedKey, for: "mac-device")
        let receiverEngine = SyncEngine(
            transport: NoopTransport(),
            keyProvider: receiverProvider,
            localDeviceId: "android-device"
        )

        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try await receiverEngine.decode(encoded)
        XCTAssertEqual(decoded.contentType, payload.contentType)
        XCTAssertEqual(decoded.data, payload.data)
    }

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

        let encoded = try! JSONEncoder().encode(envelope)

        await assertThrowsErrorAsync(try await engine.decode(encoded)) { error in
            guard let providerError = error as? DeviceKeyProviderError else {
                XCTFail("expected DeviceKeyProviderError")
                return
            }
            switch providerError {
            case .missingKey(let deviceId):
                XCTAssertEqual(deviceId, "mac-device")
            }
        }
    }
}

private final class RecordingTransport: SyncTransport {
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

private func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
