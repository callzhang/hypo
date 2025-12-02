#if canImport(SwiftUI)
import Foundation
import SwiftUI

@MainActor
public final class RemotePairingViewModel: ObservableObject {
    public enum ViewState: Equatable {
        case idle
        case requestingCode
        case displaying(code: String, expiresAt: Date)
        case awaitingChallenge(code: String, expiresAt: Date)
        case completing
        case completed
        case failed(String)
    }

    @Published public private(set) var state: ViewState = .idle
    @Published public private(set) var statusMessage: String = "Request a pairing code to begin"
    @Published public private(set) var countdownText: String?

    private let session: PairingSession
    private let identity: DeviceIdentityProviding
    private let relayClientFactory: @Sendable (URL) -> PairingRelayClient
    private let onDevicePaired: (PairedDevice) -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var relayClient: PairingRelayClient?
    private var pollTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var activeCode: String?

    public init(
        identity: DeviceIdentityProviding = DeviceIdentity(),
        sessionFactory: (UUID) -> PairingSession = { PairingSession(identity: $0) },
        relayClientFactory: @escaping @Sendable (URL) -> PairingRelayClient = { PairingRelayClient(baseURL: $0) },
        onDevicePaired: @escaping (PairedDevice) -> Void = { _ in }
    ) {
        self.identity = identity
        self.session = sessionFactory(identity.deviceId)
        self.relayClientFactory = relayClientFactory
        self.onDevicePaired = onDevicePaired
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.session.delegate = self
    }

    deinit {
        pollTask?.cancel()
        countdownTask?.cancel()
    }

    public func start(service: String, port: Int, relayHint: URL?) {
        reset()
        guard let relayHint else {
            state = .failed("Relay configuration missing")
            statusMessage = "Relay configuration missing"
            return
        }
        state = .requestingCode
        statusMessage = "Requesting pairing code…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let configuration = PairingSession.Configuration(
                    service: service,
                    port: port,
                    relayHint: relayHint,
                    deviceName: identity.deviceName
                )
                try session.start(with: configuration)
                guard let payload = session.currentPayload() else {
                    throw PairingRelayClient.Error.invalidResponse
                }
                let client = relayClientFactory(relayHint)
                self.relayClient = client
                let code = try await client.createPairingCode(
                    initiatorDeviceId: payload.peerDeviceId,
                    initiatorDeviceName: identity.deviceName,
                    initiatorPublicKey: payload.peerPublicKey
                )
                await MainActor.run {
                    self.activeCode = code.code
                    self.state = .displaying(code: code.code, expiresAt: code.expiresAt)
                    self.statusMessage = "Share this code with your Android device"
                    self.startCountdown(until: code.expiresAt)
                    self.beginPollingChallenge(code: code.code, payload: payload)
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }

    public func reset() {
        pollTask?.cancel()
        pollTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        activeCode = nil
        relayClient = nil
        state = .idle
        statusMessage = "Request a pairing code to begin"
        countdownText = nil
    }

    private func startCountdown(until expiry: Date) {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let remaining = expiry.timeIntervalSinceNow
                await MainActor.run {
                    if remaining <= 0 {
                        self.countdownText = nil
                        if case .completed = self.state { return }
                        self.pollTask?.cancel()
                        self.state = .failed("Pairing code expired")
                        self.statusMessage = "Pairing code expired"
                    } else {
                        let seconds = Int(remaining.rounded())
                        self.countdownText = "Expires in \(seconds)s"
                    }
                }
                if remaining <= 0 { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func beginPollingChallenge(code: String, payload: PairingPayload) {
        pollTask?.cancel()
        state = .awaitingChallenge(code: code, expiresAt: payload.expiresAt)
        statusMessage = "Waiting for Android device…"
        pollTask = Task { [weak self] in
            guard let self, let relayClient else { return }
            while !Task.isCancelled {
                do {
                    let challengeJSON = try await relayClient.pollChallenge(code: code, initiatorDeviceId: payload.peerDeviceId)
                    let messageData = Data(challengeJSON.utf8)
                    let message = try decoder.decode(PairingChallengeMessage.self, from: messageData)
                    await MainActor.run {
                        self.statusMessage = "Processing challenge…"
                        self.state = .completing
                    }
                    if let ack = await session.handleChallenge(message) {
                        let ackData = try encoder.encode(ack)
                        let ackJSON = String(decoding: ackData, as: UTF8.self)
                        try await relayClient.submitAck(code: code, initiatorDeviceId: payload.peerDeviceId, ackJSON: ackJSON)
                        return
                    }
                } catch let error as PairingRelayClient.Error {
                    switch error {
                    case .challengeNotReady:
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        continue
                    case .codeExpired:
                        await MainActor.run {
                            self.state = .failed("Pairing code expired")
                            self.statusMessage = "Pairing code expired"
                        }
                        return
                    default:
                        await MainActor.run {
                            self.state = .failed(error.localizedDescription)
                            self.statusMessage = error.localizedDescription
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        self.state = .failed(error.localizedDescription)
                        self.statusMessage = error.localizedDescription
                    }
                    return
                }
            }
        }
    }
}

extension RemotePairingViewModel: PairingSessionDelegate {
    public func pairingSession(_ session: PairingSession, didCompleteWith device: PairedDevice) {
        countdownTask?.cancel()
        countdownTask = nil
        state = .completed
        statusMessage = "Paired with \(device.name)"
        onDevicePaired(device)
    }

    public func pairingSession(_ session: PairingSession, didFailWith error: Error) {
        countdownTask?.cancel()
        countdownTask = nil
        state = .failed(error.localizedDescription)
        statusMessage = error.localizedDescription
    }
}
#endif
