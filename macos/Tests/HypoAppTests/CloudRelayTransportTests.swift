import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@_spi(Testing) @testable import HypoApp

struct CloudRelayTransportTests {
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
        let transport = CloudRelayTransport(
            configuration: .init(
                url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
                fingerprint: "abcd"
            )
        )

        let mirror = Mirror(reflecting: transport.underlying)
        let configuration = mirror.descendant("configuration") as? WebSocketConfiguration
        #expect(configuration?.environment == "cloud")
    }

    @Test @MainActor
    func testQueryConnectedPeersUsesNameLookup() async {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = CloudRelayTransport(
            configuration: .init(
                url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
                fingerprint: "abcd"
            ),
            sessionFactory: { _, _ in session }
        )
        transport.setNameLookup { deviceId in
            deviceId == "peer-a" ? "Alice" : nil
        }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try? await transport.connect()

        async let response = transport.queryConnectedPeers(peerIds: ["peer-a"])
        let sent = await waitUntil(timeout: .seconds(1)) {
            stubTask.sentData.count == 1
        }
        #expect(sent)

        let sentData = stubTask.sentData.first ?? Data()
        let json = jsonObject(from: sentData) ?? [:]
        let queryId = json["id"] as? String ?? ""

        let payload: [String: Any] = [
            "type": "control",
            "payload": [
                "action": "query_connected_peers",
                "original_message_id": queryId,
                "connected_devices": ["peer-a"]
            ]
        ]
        transport.underlying._testing_handleIncoming(lengthPrefixedJSON(payload))

        let peers = await response
        #expect(peers.count == 1)
        #expect(peers.first?.deviceId == "peer-a")
        #expect(peers.first?.name == "Alice")
    }

    @Test @MainActor
    func testReconnectRestartsConnection() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = CloudRelayTransport(
            configuration: .init(
                url: URL(string: "wss://hypo-relay-staging.fly.dev/ws")!,
                fingerprint: "abcd"
            ),
            sessionFactory: { _, _ in session }
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
