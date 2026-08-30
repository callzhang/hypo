import SwiftUI
import HypoCore

/// Pushed from the devices section of Settings, the way Android reaches it.
public struct PairingView: View {
    @ObservedObject private var viewModel: RemotePairingViewModel
    @ObservedObject private var claimViewModel: ClaimPairingCodeViewModel
    private let relayHint: URL?

    public init(
        viewModel: RemotePairingViewModel,
        claimViewModel: ClaimPairingCodeViewModel,
        relayHint: URL?
    ) {
        self.viewModel = viewModel
        self.claimViewModel = claimViewModel
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

            Divider()
                .padding(.vertical, 8)

            // The other half. Pairing needs one device to show a code and the
            // other to claim it, so an app that can only show one can only
            // pair with something that can claim — which, until this existed,
            // meant Android and nothing else.
            VStack(spacing: 12) {
                Text(claimViewModel.statusMessage)
                    .multilineTextAlignment(.center)
                    .font(.callout)

                TextField("Code from the other device", text: $claimViewModel.code)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(.title3, design: .monospaced))
                    .accessibilityIdentifier("PairingCodeField")

                Button("Enter this code") {
                    claimViewModel.claim(relayHint: relayHint)
                }
                .buttonStyle(.bordered)
                .disabled(!claimViewModel.canSubmit)
            }
        }
        .padding()
        .navigationTitle("Pair a device")
    }
}
