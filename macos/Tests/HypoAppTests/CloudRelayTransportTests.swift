import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@_spi(Testing) @testable import HypoApp

struct CloudRelayTransportTests {
    @Test @MainActor
    func testDefaultsIncludeAuthTokenWhenConfigured() async {
        setenv("RELAY_WS_AUTH_TOKEN", "test-secret", 1)
        defer { unsetenv("RELAY_WS_AUTH_TOKEN") }

        let configuration = CloudRelayDefaults.production()
        #expect(configuration.headers["X-Auth-Token"] != nil)
    }
    @Test @MainActor
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
        #expect(stubTask.sentData.count == 1)
    }

    @Test @MainActor
    func testConfigurationUsesCloudEnvironment() async {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let transport = CloudRelayTransport(
            configuration: .init(
                url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
                fingerprint: "abcd"
            ),
            urlSession: session
        )

        let mirror = Mirror(reflecting: transport.underlying)
        let configuration = mirror.descendant("configuration") as? WebSocketConfiguration
        #expect(configuration?.environment == "cloud")
    }

    @Test @MainActor
    func testQueryConnectedPeersUsesNameLookup() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let httpSession = URLSession(configuration: config)

        let transport = CloudRelayTransport(
            configuration: .init(
                url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
                fingerprint: "abcd"
            ),
            urlSession: httpSession
        )
        transport.setNameLookup { deviceId in
            deviceId == "peer-a" ? "Alice" : nil
        }

        let responseData = """
        {"connected_devices":[{"device_id":"peer-a","last_seen":"2025-10-01T12:35:10.123Z"}]}
        """.data(using: .utf8) ?? Data()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, responseData)
        }

        let peers = await transport.queryConnectedPeers(peerIds: ["peer-a"])
        #expect(peers.count == 1)
        #expect(peers.first?.deviceId == "peer-a")
        #expect(peers.first?.name == "Alice")
    }

    @Test @MainActor
    func testReconnectRestartsConnection() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let httpSession = URLSession(configuration: config)

        let transport = CloudRelayTransport(
            configuration: .init(
                url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
                fingerprint: "abcd"
            ),
            sessionFactory: { _, _ in session },
            urlSession: httpSession
        )

        let resumes = Locked(0)
        stubTask.onResume = {
            resumes.withLock { $0 += 1 }
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        await transport.reconnect()

        let fulfilled = await waitUntil(timeout: .seconds(2)) {
            resumes.withLock { $0 } >= 2
        }
        #expect(fulfilled)
    }

    @Test @MainActor
    func testSetOnIncomingMessageForwardsToHandler() async throws {
        let transport = CloudRelayTransport(
            configuration: .init(
                url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
                fingerprint: "abcd"
            )
        )

        let received = Locked(false)
        transport.setOnIncomingMessage { _, origin in
            if origin == .cloud {
                received.withLock { $0 = true }
            }
        }

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))
        let encoded = try TransportFrameCodec().encode(envelope)
        transport.underlying._testing_handleIncoming(encoded)

        let fulfilled = await waitUntil(timeout: .seconds(1)) {
            received.withLock { $0 }
        }
        #expect(fulfilled)
    }
}

private func lengthPrefixedJSON(_ object: [String: Any]) -> Data {
    let jsonData = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    var length = UInt32(jsonData.count).bigEndian
    var data = Data()
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(jsonData)
    return data
}

private func jsonObject(from data: Data) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
