import Foundation
import Testing
@testable import HypoCore

#if os(macOS)
@MainActor
struct DebugStatusServerTests {
    @Test
    func testServesTheSnapshotOverLoopback() async throws {
        // A high port so a stray copy of the app on the default one cannot make this
        // test pass or fail for the wrong reason.
        let port = 47_311
        let server = DebugStatusServer(port: port) { makeStatus() }
        try server.start()
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/status")!
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(DebugStatus.self, from: data)
        #expect(status.deviceName == "Test Mac")
        #expect(status.hasRelayToken == false)
        #expect(status.pairedDevices.map(\.name) == ["Peer One"])
        #expect(status.discoveredPeers.first?.advertisesPairingKey == true)
    }

    @Test
    func testUnknownPathIsNotFound() async throws {
        let port = 47_312
        let server = DebugStatusServer(port: port) { makeStatus() }
        try server.start()
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/something-else")!
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    private func makeStatus() -> DebugStatus {
        DebugStatus(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            version: "1.2.0",
            deviceId: "aaaa1111",
            deviceName: "Test Mac",
            platform: "macos",
            hasRelayToken: false,
            connectionState: "connectedCloud",
            lanServerPort: 7010,
            publishedPeerCount: 1,
            pairablePeers: [],
            pairedDevices: [
                DebugStatus.Device(
                    id: "bbbb2222",
                    name: "Peer One",
                    platform: "Android",
                    isOnline: true,
                    lastSeen: Date(timeIntervalSince1970: 900),
                    bonjourHost: "peer.local",
                    bonjourPort: 7010
                )
            ],
            discoveredPeers: [
                DebugStatus.Peer(
                    serviceName: "peer-one",
                    host: "peer.local",
                    port: 7010,
                    deviceId: "bbbb2222",
                    advertisesPairingKey: true,
                    isPaired: true,
                    lastSeen: Date(timeIntervalSince1970: 900)
                )
            ]
        )
    }
}
#endif
