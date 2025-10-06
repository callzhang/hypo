import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HypoApp

final class LanWebSocketTransportTests: XCTestCase {
    func testConnectResolvesAfterHandshake() async throws {
        let expectation = expectation(description: "handshake")
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        )

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
            expectation.fulfill()
        }

        try await transport.connect()
        await fulfillment(of: [expectation], timeout: 0.5)
    }

    func testSendUsesFrameCodec() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let codec = TransportFrameCodec()
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            frameCodec: codec,
            sessionFactory: { _, _ in session }
        )

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))

        try await transport.send(envelope)
        XCTAssertEqual(stubTask.sentData.count, 1)
        let decoded = try codec.decode(stubTask.sentData[0])
        XCTAssertEqual(decoded.payload.deviceId, "device")
    }

    func testIdleTimeoutCancelsTask() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil, idleTimeout: 0.05),
            sessionFactory: { _, _ in session }
        )
        let cancelExpectation = expectation(description: "cancelled")
        stubTask.onCancel = { (_: URLSessionWebSocketTask.CloseCode, _: Data?) in cancelExpectation.fulfill() }
        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        await fulfillment(of: [cancelExpectation], timeout: 1.0)
    }

    func testMetricsRecorderCapturesHandshakeAndRoundTrip() async throws {
        let handshakeExpectation = expectation(description: "handshake metric")
        let roundTripExpectation = expectation(description: "round trip metric")
        let metrics = RecordingMetricsRecorder(
            handshakeExpectation: handshakeExpectation,
            roundTripExpectation: roundTripExpectation
        )
        let codec = TransportFrameCodec()
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            frameCodec: codec,
            metricsRecorder: metrics,
            sessionFactory: { _, _ in session }
        )

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))

        try await transport.send(envelope)
        let echo = try codec.encode(envelope)
        stubTask.receiveHandler?(.success(.data(echo)))

        await fulfillment(of: [handshakeExpectation, roundTripExpectation], timeout: 1.0)
        XCTAssertEqual(metrics.recordedHandshakes.count, 1)
        XCTAssertEqual(metrics.recordedRoundTrips[envelope.id]?.count ?? 0, 1)
    }
}

private final class StubSession: URLSessionProviding {
    private let task: StubWebSocketTask

    init(task: StubWebSocketTask) {
        self.task = task
    }

    func webSocketTask(with request: URLRequest) -> WebSocketTasking {
        task.createdRequest = request
        return task
    }

    func invalidateAndCancel() {}
}

private final class StubWebSocketTask: WebSocketTasking {
    var createdRequest: URLRequest?
    var onResume: (() -> Void)?
    var onCancel: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var sentData: [Data] = []
    var receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

    func resume() {
        onResume?()
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        if case .data(let data) = message {
            sentData.append(data)
        }
        completionHandler(nil)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onCancel?(closeCode, reason)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveHandler = completionHandler
    }
}

private final class RecordingMetricsRecorder: TransportMetricsRecorder {
    private(set) var recordedHandshakes: [TimeInterval] = []
    private(set) var recordedRoundTrips: [UUID: [TimeInterval]] = [:]
    private let handshakeExpectation: XCTestExpectation?
    private let roundTripExpectation: XCTestExpectation?

    init(handshakeExpectation: XCTestExpectation?, roundTripExpectation: XCTestExpectation?) {
        self.handshakeExpectation = handshakeExpectation
        self.roundTripExpectation = roundTripExpectation
    }

    func recordHandshake(duration: TimeInterval, timestamp: Date) {
        recordedHandshakes.append(duration)
        handshakeExpectation?.fulfill()
    }

    func recordRoundTrip(envelopeId: UUID, duration: TimeInterval) {
        var durations = recordedRoundTrips[envelopeId, default: []]
        durations.append(duration)
        recordedRoundTrips[envelopeId] = durations
        roundTripExpectation?.fulfill()
    }
}
