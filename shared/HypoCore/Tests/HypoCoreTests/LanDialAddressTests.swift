import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@_spi(Testing) @testable import HypoCore

/// A LAN peer is only reachable on the port it advertises over Bonjour, so the
/// dialled URL has to carry that port. Stripping the query used to rebuild the
/// URL from scheme and host alone, which silently sent every peer dial to :80.
struct LanDialAddressTests {
    @Test
    func testWebSocketTransportDialsTheAdvertisedPort() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(
                url: URL(string: "ws://192.168.1.42:7010")!,
                pinnedFingerprint: nil,
                environment: "lan"
            ),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = { transport.handleOpen(task: stubTask) }
        try await transport.connect()

        #expect(stubTask.createdRequest?.url?.port == 7010)
        #expect(stubTask.createdRequest?.url?.absoluteString == "ws://192.168.1.42:7010/ws")
        await transport.disconnect()
    }

    @Test
    func testWebSocketTransportKeepsThePortWhileDroppingTheQuery() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(
                url: URL(string: "ws://192.168.1.42:7010/ws?device_id=abc")!,
                pinnedFingerprint: nil,
                environment: "lan"
            ),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = { transport.handleOpen(task: stubTask) }
        try await transport.connect()

        #expect(stubTask.createdRequest?.url?.absoluteString == "ws://192.168.1.42:7010/ws")
        await transport.disconnect()
    }

    @Test
    func testLanWebSocketTransportDialsTheAdvertisedPort() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(
                url: URL(string: "ws://192.168.1.42:7010/ws?device_id=abc")!,
                pinnedFingerprint: nil,
                environment: "lan"
            ),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = { transport.handleOpen(task: stubTask) }
        try await transport.connect()

        #expect(stubTask.createdRequest?.url?.port == 7010)
        #expect(stubTask.createdRequest?.url?.absoluteString == "ws://192.168.1.42:7010/ws")
        await transport.disconnect()
    }

    /// The cloud relay is addressed by its configured URL, query and all.
    @Test
    func testCloudConnectionIsLeftAlone() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(
                url: URL(string: "wss://hypo.fly.dev/ws?device_id=abc")!,
                pinnedFingerprint: nil,
                environment: "cloud"
            ),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = { transport.handleOpen(task: stubTask) }
        try await transport.connect()

        #expect(stubTask.createdRequest?.url?.absoluteString == "wss://hypo.fly.dev/ws?device_id=abc")
        await transport.disconnect()
    }
}
