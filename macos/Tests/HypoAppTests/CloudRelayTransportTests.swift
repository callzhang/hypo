import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HypoApp

final class CloudRelayTransportTests: XCTestCase {
    func testSendDelegatesToUnderlyingTransport() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = CloudRelayTransport(
            configuration: .init(
                url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
                fingerprint: "abcd"
            ),
            frameCodec: TransportFrameCodec(),
            sessionFactory: { _, _ in session }
        )

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: .init(
                contentType: .text,
                ciphertext: Data([0x01]),
                deviceId: "mac",
                target: "android",
                encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
            )
        )

        try await transport.send(envelope)
        XCTAssertEqual(stubTask.sentData.count, 1)
    }

    func testConfigurationUsesCloudEnvironment() {
        let transport = CloudRelayTransport(
            configuration: .init(
                url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
                fingerprint: "abcd"
            )
        )

        let mirror = Mirror(reflecting: transport.underlying)
        let configuration = mirror.descendant("configuration") as? WebSocketConfiguration
        XCTAssertEqual(configuration?.environment, "cloud")
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
