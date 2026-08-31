#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// Lists the devices on this network so one can be tapped to pair with, the
/// way Android's auto-discovery mode does.
///
/// Pairing by typing a six-digit code is the fallback for devices that cannot
/// see each other; on one network it should not be the only option.
@MainActor
public final class LanPairingViewModel: ObservableObject {
    public enum State: Equatable {
        case discovering
        case found([DiscoveredPeer])
        case pairing(deviceName: String)
        case paired(deviceName: String)
        case failed(String)
    }

    @Published public private(set) var state: State = .discovering

    private let discoveredPeers: @MainActor () -> [DiscoveredPeer]
    private let pairedDeviceIds: @MainActor () -> Set<String>
    private let pairWithPeer: @Sendable (DiscoveredPeer) async throws -> PairedDevice
    private var refreshTask: Task<Void, Never>?
    private var pairTask: Task<Void, Never>?

    public init(
        discoveredPeers: @escaping @MainActor () -> [DiscoveredPeer],
        pairedDeviceIds: @escaping @MainActor () -> Set<String> = { [] },
        pairWithPeer: @escaping @Sendable (DiscoveredPeer) async throws -> PairedDevice
    ) {
        self.discoveredPeers = discoveredPeers
        self.pairedDeviceIds = pairedDeviceIds
        self.pairWithPeer = pairWithPeer
    }

    /// Pairs with a device the user tapped.
    public func pair(with peer: DiscoveredPeer) {
        guard case .found = state else { return }
        state = .pairing(deviceName: peer.serviceName)
        pairTask?.cancel()
        pairTask = Task { [weak self] in
            guard let self else { return }
            do {
                let device = try await self.pairWithPeer(peer)
                self.state = .paired(deviceName: device.name)
            } catch is CancellationError {
                return
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        pairTask?.cancel()
    }

    /// Polls rather than subscribes: discovery already writes into
    /// TransportManager, and a second subscription would be a second source of
    /// truth to keep in step.
    public func startDiscovery() {
        // Idempotent, and never clobbers an outcome. SwiftUI calls onAppear
        // more than once, and resetting to .discovering there threw away a
        // pairing that was already under way: the tap sent its challenge, the
        // peer accepted it, and the screen went back to listing devices as if
        // nothing had happened.
        guard refreshTask == nil else { return }
        if case .discovering = state {} else if case .found = state {} else { return }

        state = .discovering
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let peers = self.discoveredPeers()
                switch self.state {
                case .pairing, .paired, .failed:
                    // Leave outcomes alone. Overwriting .failed also meant an
                    // error message vanished two seconds after appearing.
                    break
                default:
                    self.state = .found(peers)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    public func stopDiscovery() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Starts fresh after an outcome, which is what the Done and Try again
    /// buttons do.
    public func restartDiscovery() {
        stopDiscovery()
        state = .discovering
        startDiscovery()
    }

    public func isPaired(_ peer: DiscoveredPeer) -> Bool {
        guard let deviceId = peer.endpoint.metadata["device_id"] else { return false }
        return pairedDeviceIds().contains(deviceId.lowercased())
    }

    public func reset() {
        restartDiscovery()
    }
}
#endif
