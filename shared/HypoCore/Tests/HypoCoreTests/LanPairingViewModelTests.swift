#if canImport(SwiftUI)
import Testing
import Foundation
@testable import HypoCore

/// Telling an empty network apart from a denied permission.
///
/// iOS offers no API to ask whether local network access was refused, and a
/// refusal raises no error — Bonjour returns nothing, forever. The only signal
/// available is that discovery has been empty for a while, so that is what the
/// view model reports and what the settings screen acts on.
@Suite("LAN discovery hint")
@MainActor
struct LanPairingViewModelTests {
    private func peer(_ name: String) -> DiscoveredPeer {
        DiscoveredPeer(
            serviceName: name,
            endpoint: LanEndpoint(host: "192.168.1.2", port: 7010, metadata: [:]),
            lastSeen: Date()
        )
    }

    @Test("says nothing while discovery is young")
    func quietAtFirst() async {
        let model = LanPairingViewModel(discoveredPeers: { [] }, pairWithPeer: { _ in throw CancellationError() })
        model.startDiscovery()

        // One round is not evidence of anything.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.foundNothingForAWhile == false)
        model.stopDiscovery()
    }

    @Test("a peer clears the count")
    func peerResetsIt() async {
        let found = Locked(false)
        let model = LanPairingViewModel(
            discoveredPeers: { found.withLock { $0 } ? [self.peer("Mac")] : [] },
            pairWithPeer: { _ in throw CancellationError() }
        )
        model.startDiscovery()
        try? await Task.sleep(for: .milliseconds(200))
        found.withLock { $0 = true }
        try? await Task.sleep(for: .milliseconds(2_400))

        #expect(model.foundNothingForAWhile == false)
        if case .found(let peers) = model.state {
            #expect(peers.count == 1)
        } else {
            Issue.record("expected peers, got \(model.state)")
        }
        model.stopDiscovery()
    }

    @Test("restarting discovery forgets what it saw")
    func resetClearsIt() async {
        let model = LanPairingViewModel(discoveredPeers: { [] }, pairWithPeer: { _ in throw CancellationError() })
        model.startDiscovery()
        try? await Task.sleep(for: .milliseconds(200))

        model.reset()

        #expect(model.foundNothingForAWhile == false)
        model.stopDiscovery()
    }
}
#endif
