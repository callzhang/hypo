import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HypoApp

final class TransportFrameCodecTests: XCTestCase {
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
        XCTAssertEqual(decoded.payload.deviceId, "deviceA")
        XCTAssertEqual(decoded.payload.target, "deviceB")
        XCTAssertEqual(decoded.payload.ciphertext, Data([0x01, 0x02, 0x03]))
    }

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
        let vector = try XCTUnwrap(json?.first)
        let base64 = try XCTUnwrap(vector["base64"] as? String)
        let envelope = try XCTUnwrap(vector["envelope"] as? [String: Any])
        let payload = try XCTUnwrap(envelope["payload"] as? [String: Any])
        let deviceId = try XCTUnwrap(payload["device_id"] as? String)

        let frame = try XCTUnwrap(Data(base64Encoded: base64))
        let decoded = try codec.decode(frame)
        XCTAssertEqual(decoded.payload.deviceId, deviceId)
        let reEncoded = try codec.encode(decoded)
        let originalPayloadData = frame.subdata(in: 4..<frame.count)
        let reEncodedPayloadData = reEncoded.subdata(in: 4..<reEncoded.count)
        let originalPayload = try JSONSerialization.jsonObject(with: originalPayloadData) as? NSDictionary
        let reEncodedPayload = try JSONSerialization.jsonObject(with: reEncodedPayloadData) as? NSDictionary
        XCTAssertEqual(originalPayload, reEncodedPayload)
    }

    func testDecodeTruncatedThrows() {
        let codec = TransportFrameCodec()
        XCTAssertThrowsError(try codec.decode(Data([0x00, 0x00, 0x00, 0x05, 0x01]))) { error in
            XCTAssertEqual(error as? TransportFrameError, .truncated)
        }
    }

    func testPayloadTooLargeThrows() {
        let codec = TransportFrameCodec(maxPayloadSize: 1)
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x00]),
            deviceId: "device",
            target: nil,
            encryption: .init(nonce: Data([0x00]), tag: Data([0x01]))
        ))
        XCTAssertThrowsError(try codec.encode(envelope)) { error in
            XCTAssertEqual(error as? TransportFrameError, .payloadTooLarge)
        }
    }
}
