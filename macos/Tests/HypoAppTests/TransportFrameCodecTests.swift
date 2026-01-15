import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HypoApp

struct TransportFrameCodecTests {
    @Test
    func testRoundTrip() throws {
        let codec = TransportFrameCodec()
        let envelope = SyncEnvelope(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            timestamp: ISO8601DateFormatter().date(from: "2025-10-03T12:00:00Z")!,
            version: "1.0",
            type: .clipboard,
            payload: .init(
                contentType: .text,
                ciphertext: Data([0x01, 0x02, 0x03]),
                deviceId: "deviceA",
                target: "deviceB",
                encryption: .init(nonce: Data([0x04, 0x05, 0x06]), tag: Data([0x07, 0x08, 0x09]))
            )
        )

        let encoded = try codec.encode(envelope)
        let decoded = try codec.decode(encoded)
        #expect(decoded.payload.deviceId == "deviceA")
        #expect(decoded.payload.target == "deviceB")
        #expect(decoded.payload.ciphertext == Data([0x01, 0x02, 0x03]))
    }

    @Test
    func testEncodesKnownVector() throws {
        let codec = TransportFrameCodec()
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = fileURL
            .deletingLastPathComponent() // TransportFrameCodecTests.swift
            .deletingLastPathComponent() // HypoAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
        let vectorsURL = repoRoot.appendingPathComponent("tests/transport/frame_vectors.json")
        let data = try Data(contentsOf: vectorsURL)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]]
        let vector = try #require(json?.first)
        let base64 = try #require(vector["base64"] as? String)
        let envelope = try #require(vector["envelope"] as? [String: Any])
        let payload = try #require(envelope["payload"] as? [String: Any])
        let deviceId = try #require(payload["device_id"] as? String)

        let frame = try #require(Data(base64Encoded: base64))
        let decoded = try codec.decode(frame)
        #expect(decoded.payload.deviceId == deviceId)
        let reEncoded = try codec.encode(decoded)
        let originalPayloadData = frame.subdata(in: 4..<frame.count)
        let reEncodedPayloadData = reEncoded.subdata(in: 4..<reEncoded.count)
        let originalPayload = try JSONSerialization.jsonObject(with: originalPayloadData) as? NSDictionary
        let reEncodedPayload = try JSONSerialization.jsonObject(with: reEncodedPayloadData) as? NSDictionary
        #expect(originalPayload == reEncodedPayload)
    }

    @Test
    func testDecodeTruncatedThrows() {
        let codec = TransportFrameCodec()
        do {
            _ = try codec.decode(Data([0x00, 0x00, 0x00, 0x05, 0x01]))
            #expect(false)
        } catch {
            #expect(error as? TransportFrameError == .truncated)
        }
    }

    @Test
    func testPayloadTooLargeThrows() {
        let codec = TransportFrameCodec(maxPayloadSize: 1)
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x00]),
            deviceId: "device",
            target: nil,
            encryption: .init(nonce: Data([0x00]), tag: Data([0x01]))
        ))
        do {
            _ = try codec.encode(envelope)
            #expect(false)
        } catch {
            #expect(error as? TransportFrameError == .payloadTooLarge)
        }
    }

    @Test
    func testDecodeRejectsOversizedPayload() throws {
        let codec = TransportFrameCodec()
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data("payload".utf8),
            deviceId: "device",
            target: nil,
            encryption: .init(nonce: Data("nonce".utf8), tag: Data("tag".utf8))
        ))
        let frame = try codec.encode(envelope)
        let strict = TransportFrameCodec(maxPayloadSize: 8)
        do {
            _ = try strict.decode(frame)
            #expect(false)
        } catch {
            #expect(error as? TransportFrameError == .payloadTooLarge)
        }
    }
}
