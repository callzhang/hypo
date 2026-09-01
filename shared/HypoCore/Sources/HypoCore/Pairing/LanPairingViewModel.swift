#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// The devices on this network, so one can be tapped to pair with.
///
/// Pairing by typing a six-digit code is the fallback for devices that cannot
/// see each other; on one network it should not be the only option.
///
/// The list and the pairing attempt are separate on purpose. They used to share
/// one state enum, and every outcome except "found" stopped the list from
/// refreshing and made taps do nothing — so one failed attempt froze the screen
/// until it was left and reopened. A device appearing on the network has
/// nothing to do with whether the last attempt worked.
@MainActor
public final class LanPairingViewModel: ObservableObject {
    public enum Pairing: Equatable {
        case inProgress(deviceName: String)
        case succeeded(deviceName: String)
        case failed(String)
    }

    /// Everything discovered, refreshed while discovery runs.
    @Published public private(set) var peers: [DiscoveredPeer] = []

    /// Whether discovery has produced anything yet.
    @Published public private(set) var hasSearched = false

    /// The last attempt, if there has been one.
    @Published public private(set) var pairing: Pairing?

    /// True once discovery has run a while and turned up nothing.
    ///
    /// This is the only signal iOS gives that local network access was denied.
    /// There is no API to ask, and a denial does not raise an error — Bonjour
    /// simply returns nothing, forever, which is indistinguishable from an
    /// empty network until you notice it is always empty.
    @Published public private(set) var foundNothingForAWhile = false

    private let discoveredPeers: @MainActor () -> [DiscoveredPeer]
    private let pairedDeviceIds: @MainActor () -> Set<String>
    private let pairWithPeer: @Sendable (DiscoveredPeer) async throws -> PairedDevice
    private var refreshTask: Task<Void, Never>?
    private var pairTask: Task<Void, Never>?
    private var emptyRounds = 0

    public init(
        discoveredPeers: @escaping @MainActor () -> [DiscoveredPeer],
        pairedDeviceIds: @escaping @MainActor () -> Set<String> = { [] },
        pairWithPeer: @escaping @Sendable (DiscoveredPeer) async throws -> PairedDevice
    ) {
        self.discoveredPeers = discoveredPeers
        self.pairedDeviceIds = pairedDeviceIds
        self.pairWithPeer = pairWithPeer
    }

    deinit { refreshTask?.cancel() }

    /// Polls rather than subscribes: discovery already writes into
    /// TransportManager, and a second subscription would be a second source of
    /// truth to keep in step.
    public func startDiscovery() {
        refreshTask?.cancel()
        emptyRounds = 0
        foundNothingForAWhile = false
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.peers = self.discoveredPeers()
                self.hasSearched = true
                if self.peers.isEmpty {
                    self.emptyRounds += 1
                } else {
                    self.emptyRounds = 0
                }
                // Six rounds at two seconds: long enough that a slow network
                // has answered, short enough to matter.
                self.foundNothingForAWhile = self.emptyRounds >= 6
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    public func stopDiscovery() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Devices found here that are not paired yet.
    ///
    /// A paired device would otherwise be listed twice: once as something to
    /// manage and once as something to pair with.
    public var unpairedPeers: [DiscoveredPeer] {
        let paired = pairedDeviceIds()
        return peers.filter { peer in
            guard let id = peer.endpoint.metadata["device_id"]?.lowercased() else { return true }
            return !paired.contains(id)
        }
    }

    public func isPaired(_ peer: DiscoveredPeer) -> Bool {
        guard let deviceId = peer.endpoint.metadata["device_id"] else { return false }
        return pairedDeviceIds().contains(deviceId.lowercased())
    }

    /// Pairs with a device the user tapped.
    ///
    /// Allowed whatever the last attempt did — refusing while a previous
    /// failure was still on screen meant a device could become permanently
    /// untappable without saying why.
    public func pair(with peer: DiscoveredPeer) {
        guard !isPairingInProgress else { return }
        pairing = .inProgress(deviceName: peer.serviceName)
        pairTask?.cancel()
        pairTask = Task { [weak self] in
            guard let self else { return }
            do {
                let device = try await self.pairWithPeer(peer)
                self.pairing = .succeeded(deviceName: device.name)
            } catch is CancellationError {
                self.pairing = nil
            } catch {
                self.pairing = .failed(error.localizedDescription)
            }
        }
    }

    public var isPairingInProgress: Bool {
        if case .inProgress = pairing { return true }
        return false
    }

    /// Clears the last outcome without touching the list.
    public func dismissPairingOutcome() {
        guard !isPairingInProgress else { return }
        pairing = nil
    }

    public func reset() {
        pairTask?.cancel()
        pairing = nil
        startDiscovery()
    }
}
#endif
