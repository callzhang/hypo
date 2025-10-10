#if canImport(SwiftUI)
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public final class PairingViewModel: ObservableObject {
    public enum ViewState {
        case loading
        case showing(image: NSImage?, payload: String)
        case awaitingHandshake
        case completed
        case failed(String)
    }

    @Published public private(set) var state: ViewState = .loading
    @Published public private(set) var statusMessage: String = "Generating secure QR code…"
    @Published public private(set) var ackJSON: String?

    private let session: PairingSession
    private let identity: DeviceIdentityProviding
    private let onDevicePaired: (PairedDevice) -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        identity: DeviceIdentityProviding = DeviceIdentity(),
        sessionFactory: (UUID) -> PairingSession = { PairingSession(identity: $0) },
        onDevicePaired: @escaping (PairedDevice) -> Void = { _ in }
    ) {
        self.identity = identity
        self.session = sessionFactory(identity.deviceId)
        self.onDevicePaired = onDevicePaired
        self.session.delegate = self
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func start(service: String, port: Int, relayHint: URL?) {
        do {
            let configuration = PairingSession.Configuration(
                service: service,
                port: port,
                relayHint: relayHint,
                deviceName: identity.deviceName
            )
            try session.start(with: configuration)
            guard let cgImage = session.qrCodeImage() else {
                state = .failed("Unable to render QR code")
                statusMessage = "Failed to create QR code"
                return
            }
            let qr = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            let payload = try session.qrPayloadJSON()
            state = .showing(image: qr, payload: payload)
            statusMessage = "Scan this QR code with your Android device"
        } catch {
            state = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    public func handleChallenge(_ message: PairingChallengeMessage) {
        state = .awaitingHandshake
        statusMessage = "Processing handshake…"
        Task {
            if let ack = await session.handleChallenge(message) {
                if let data = try? encoder.encode(ack) {
                    await MainActor.run {
                        self.ackJSON = String(decoding: data, as: UTF8.self)
                    }
                }
            }
        }
    }

    public func processChallenge(json: String) {
        guard let data = json.data(using: .utf8) else {
            state = .failed("Invalid challenge payload")
            statusMessage = "Invalid challenge payload"
            return
        }
        do {
            let message = try decoder.decode(PairingChallengeMessage.self, from: data)
            handleChallenge(message)
        } catch {
            state = .failed("Failed to decode challenge")
            statusMessage = "Failed to decode challenge"
        }
    }
}

extension PairingViewModel: PairingSessionDelegate {
    public func pairingSession(_ session: PairingSession, didCompleteWith device: PairedDevice) {
        state = .completed
        statusMessage = "Paired with \(device.name)"
        onDevicePaired(device)
    }

    public func pairingSession(_ session: PairingSession, didFailWith error: Error) {
        state = .failed(error.localizedDescription)
        statusMessage = error.localizedDescription
    }
}
#endif
