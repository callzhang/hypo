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
private struct PairingRefused: Error {}

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
        #expect(model.peers.count == 1)
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

    @Test("a failed attempt does not stop the list refreshing")
    func listKeepsRefreshingAfterFailure() async {
        let found = Locked(false)
        let model = LanPairingViewModel(
            discoveredPeers: { found.withLock { $0 } ? [self.peer("OPPO PLP110")] : [] },
            pairWithPeer: { _ in throw PairingRefused() }
        )
        model.startDiscovery()
        try? await Task.sleep(for: .milliseconds(200))

        model.pair(with: peer("Gone"))
        try? await Task.sleep(for: .milliseconds(400))
        found.withLock { $0 = true }
        try? await Task.sleep(for: .milliseconds(2_400))

        // The list used to freeze on any outcome other than "found", so a
        // device that appeared after one failed attempt never showed up.
        #expect(model.peers.contains { $0.serviceName == "OPPO PLP110" })
        model.stopDiscovery()
    }

    @Test("a device can still be tapped after a failed attempt")
    func canRetryAfterFailure() async {
        let attempts = Locked(0)
        let model = LanPairingViewModel(
            discoveredPeers: { [self.peer("OPPO PLP110")] },
            pairWithPeer: { _ in
                attempts.withLock { $0 += 1 }
                // A real failure, not a cancellation: the view model treats
                // cancellation as "never happened" and clears the outcome, so
                // a cancelling double cannot exercise the retry path at all —
                // this test passed against the bug it was written for until
                // the error type was changed.
                throw PairingRefused()
            }
        )
        model.startDiscovery()
        try? await Task.sleep(for: .milliseconds(200))

        model.pair(with: peer("OPPO PLP110"))
        try? await Task.sleep(for: .milliseconds(400))
        model.pair(with: peer("OPPO PLP110"))
        try? await Task.sleep(for: .milliseconds(400))

        // Refusing a second attempt left a device permanently untappable.
        #expect(attempts.withLock { $0 } == 2)
        model.stopDiscovery()
    }
}
#endif
