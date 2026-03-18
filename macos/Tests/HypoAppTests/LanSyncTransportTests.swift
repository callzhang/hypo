import Foundation
import Testing
@testable import HypoApp

struct LanSyncTransportTests {
    @Test @MainActor
    func normalizedPeersKeepsNewestPeerPerDeviceId() {
        let olderPeer = DiscoveredPeer(
            serviceName: "iphone-old",
            endpoint: LanEndpoint(
                host: "192.168.1.10",
                port: 7010,
                metadata: ["device_id": "device-1"]
            ),
            lastSeen: Date(timeIntervalSince1970: 100)
        )
        let newerPeer = DiscoveredPeer(
            serviceName: "iphone-new",
            endpoint: LanEndpoint(
                host: "192.168.1.20",
                port: 7010,
                metadata: ["device_id": "device-1"]
            ),
            lastSeen: Date(timeIntervalSince1970: 200)
        )
        let separatePeer = DiscoveredPeer(
            serviceName: "ipad",
            endpoint: LanEndpoint(
                host: "192.168.1.30",
                port: 7010,
                metadata: ["device_id": "device-2"]
            ),
            lastSeen: Date(timeIntervalSince1970: 150)
        )

        let normalized = LanSyncTransport.normalizedPeers([olderPeer, newerPeer, separatePeer])

        #expect(normalized.count == 2)
        #expect(normalized.contains(where: { $0.serviceName == "iphone-new" }))
        #expect(!normalized.contains(where: { $0.serviceName == "iphone-old" }))
        #expect(normalized.contains(where: { $0.serviceName == "ipad" }))
    }

    @Test @MainActor
    func normalizedPeersFallsBackToServiceNameWithoutDeviceId() {
        let originalPeer = DiscoveredPeer(
            serviceName: "peer-service",
            endpoint: LanEndpoint(host: "10.0.0.1", port: 7010),
            lastSeen: Date(timeIntervalSince1970: 100)
        )
        let refreshedPeer = DiscoveredPeer(
            serviceName: "peer-service",
            endpoint: LanEndpoint(host: "10.0.0.2", port: 7010),
            lastSeen: Date(timeIntervalSince1970: 200)
        )

        let normalized = LanSyncTransport.normalizedPeers([originalPeer, refreshedPeer])

        #expect(normalized.count == 1)
        #expect(normalized.first?.endpoint.host == "10.0.0.2")
    }
}
