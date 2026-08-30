#if canImport(SwiftUI)
import Foundation
import SwiftUI
import CryptoKit

/// Drives the claiming side of pairing: you type the code another device is
/// showing, and this completes the handshake with it.
///
/// The counterpart to `RemotePairingViewModel`, which shows a code. Both are
/// needed for two Swift clients to pair — before this existed, macOS and iOS
/// could only ever show each other codes.
@MainActor
public final class ClaimPairingCodeViewModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case claiming
        case completed(deviceName: String)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var statusMessage: String = "Enter the code shown on the other device"
    @Published public var code: String = ""

    private let identity: DeviceIdentityProviding
    private let relayClientFactory: @Sendable (URL) -> PairingRelayClient
    private let storeSharedKey: @Sendable (SymmetricKey, String) throws -> Void
    private let onDevicePaired: (PairedDevice) -> Void
    private var task: Task<Void, Never>?

    public init(
        identity: DeviceIdentityProviding = DeviceIdentity(),
        relayClientFactory: @escaping @Sendable (URL) -> PairingRelayClient = { PairingRelayClient(baseURL: $0) },
        storeSharedKey: (@Sendable (SymmetricKey, String) throws -> Void)? = nil,
        onDevicePaired: @escaping (PairedDevice) -> Void = { _ in }
    ) {
        self.identity = identity
        self.relayClientFactory = relayClientFactory
        if let storeSharedKey {
            self.storeSharedKey = storeSharedKey
        } else {
            let provider = KeychainDeviceKeyProvider()
            self.storeSharedKey = { key, deviceId in
                try provider.store(key: key, for: deviceId)
            }
        }
        self.onDevicePaired = onDevicePaired
    }

    deinit { task?.cancel() }

    public var canSubmit: Bool {
        !code.trimmingCharacters(in: .whitespaces).isEmpty && state != .claiming
    }

    public func claim(relayHint: URL?) {
        guard let relayHint else {
            state = .failed("Relay configuration missing")
            statusMessage = "Relay configuration missing"
            return
        }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        state = .claiming
        statusMessage = "Claiming \(trimmed)…"

        let claimer = PairingCodeClaimer(
            relayClient: relayClientFactory(relayHint),
            deviceId: identity.deviceIdString,
            deviceName: identity.deviceName
        )

        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await claimer.claim(code: trimmed)
                // Store the key before announcing the device: a peer we have
                // registered but cannot decrypt for is worse than one we have
                // not registered yet.
                try self.storeSharedKey(result.sharedKey, result.peer.id)
                self.state = .completed(deviceName: result.peer.name)
                self.statusMessage = "Paired with \(result.peer.name)"
                self.onDevicePaired(result.peer)
            } catch is CancellationError {
                return
            } catch {
                self.state = .failed(error.localizedDescription)
                self.statusMessage = error.localizedDescription
            }
        }
    }

    public func reset() {
        task?.cancel()
        task = nil
        code = ""
        state = .idle
        statusMessage = "Enter the code shown on the other device"
    }
}
#endif
