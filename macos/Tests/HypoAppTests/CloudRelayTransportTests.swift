import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HypoApp

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
}


