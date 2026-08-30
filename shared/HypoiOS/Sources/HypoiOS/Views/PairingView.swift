import SwiftUI
import HypoCore

public struct PairingView: View {
    @ObservedObject private var viewModel: RemotePairingViewModel
    private let relayHint: URL?

    public init(viewModel: RemotePairingViewModel, relayHint: URL?) {
        self.viewModel = viewModel
        self.relayHint = relayHint
    }

    /// The code is carried by two states, not one: the session moves from
    /// .displaying to .awaitingChallenge as soon as the relay accepts it, and
    /// both hold the code. Rendering only .displaying made the code flash up
    /// and vanish before it could be read or typed anywhere.
    private var visibleCode: String? {
        switch viewModel.state {
        case .displaying(let code, _), .awaitingChallenge(let code, _):
            return code
        default:
            return nil
        }
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(viewModel.statusMessage)
                    .multilineTextAlignment(.center)

                if let code = visibleCode {
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                }

                if let countdown = viewModel.countdownText {
                    Text(countdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // port 0: iOS never listens, so there is no port to announce.
                // PairingSession forwards the value to the peer untouched, so a
                // zero tells the other device not to expect inbound connections.
                Button("Request pairing code") {
                    viewModel.start(service: "_hypo._tcp.", port: 0, relayHint: relayHint)
                }
                .buttonStyle(.borderedProminent)

                Button("Reset") { viewModel.reset() }
                    .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Pair a device")
        }
    }
}
