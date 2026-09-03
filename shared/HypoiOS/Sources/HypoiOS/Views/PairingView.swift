import SwiftUI
import HypoCore

/// Pairing by code, for devices that cannot see each other on a network.
///
/// Devices that *are* visible are listed and tapped in the devices section of
/// Settings instead — that section is already about devices, and putting the
/// nearby ones behind a second screen with a mode toggle made the shorter path
/// the harder one to find.
///
/// Within this screen the two halves stay mutually exclusive: show a code, or
/// enter one, never both at once.
public struct PairingView: View {
    /// Which half of code pairing the user chose. Neither is shown until they
    /// pick, because showing both is what made this confusing.
    private enum CodeStep {
        case choosing
        case showing
        case entering
    }

    @ObservedObject private var viewModel: RemotePairingViewModel
    @ObservedObject private var claimViewModel: ClaimPairingCodeViewModel
    private let relayHint: URL?

    @State private var codeStep: CodeStep = .choosing

    public init(
        viewModel: RemotePairingViewModel,
        claimViewModel: ClaimPairingCodeViewModel,
        relayHint: URL?
    ) {
        self.viewModel = viewModel
        self.claimViewModel = claimViewModel
        self.relayHint = relayHint
    }

    public var body: some View {
        VStack(spacing: 20) {
            codeContent
            Spacer(minLength: 0)
        }
        .padding(.top)
        .navigationTitle("Pair with code")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Pairing code

    @ViewBuilder
    private var codeContent: some View {
        if case .completed = viewModel.state {
            // The name comes from the status line, which is where the session
            // puts it. Saying only "Paired" leaves the user to guess which
            // device answered.
            successView(deviceName: pairedName(from: viewModel.statusMessage)) {
                viewModel.reset()
                codeStep = .choosing
            }
        } else if case .completed(let deviceName) = claimViewModel.state {
            successView(deviceName: deviceName) {
                claimViewModel.reset()
                codeStep = .choosing
            }
        } else {
            switch codeStep {
            case .choosing: codeChoice
            case .showing: showCode
            case .entering: enterCode
            }
        }
    }

    private var codeChoice: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Show a code")
                    .font(.headline)
                Text("This device shows a code and you type it on the other one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Show a code") {
                    codeStep = .showing
                    viewModel.start(service: "_hypo._tcp.", port: 0, relayHint: relayHint)
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            VStack(spacing: 8) {
                Text("Enter a code")
                    .font(.headline)
                Text("The other device shows a code and you type it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Enter a code") { codeStep = .entering }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    private var showCode: some View {
        VStack(spacing: 16) {
            Text(viewModel.statusMessage)
                .multilineTextAlignment(.center)

            // The code lives in two states — displaying, then awaitingChallenge
            // once the relay accepts it — and both must show it or it vanishes
            // before it can be typed anywhere.
            if let code = visibleCode {
                Text(code)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                ProgressView()
            }

            if let countdown = viewModel.countdownText {
                Text(countdown).font(.caption).foregroundStyle(.secondary)
            }

            Button("Cancel") {
                viewModel.reset()
                codeStep = .choosing
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var enterCode: some View {
        VStack(spacing: 16) {
            Text(claimViewModel.statusMessage)
                .multilineTextAlignment(.center)

            TextField("000000", text: $claimViewModel.code)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .accessibilityIdentifier("PairingCodeField")

            Button("Pair") { claimViewModel.claim(relayHint: relayHint) }
                .buttonStyle(.borderedProminent)
                .disabled(!claimViewModel.canSubmit)

            Button("Cancel") {
                claimViewModel.reset()
                codeStep = .choosing
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Shared outcomes

    private func successView(deviceName: String?, onDone: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(deviceName.map { "Paired with \($0)" } ?? "Paired")
                .font(.headline)
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }

    private func failureView(_ message: String, onRetry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try again", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(.top, 40)
    }

    /// Pulls the device name out of "Paired with X", which is how both view
    /// models phrase it.
    private func pairedName(from status: String) -> String? {
        let prefix = "Paired with "
        guard status.hasPrefix(prefix) else { return nil }
        return String(status.dropFirst(prefix.count))
    }

    private var visibleCode: String? {
        switch viewModel.state {
        case .displaying(let code, _), .awaitingChallenge(let code, _):
            return code
        default:
            return nil
        }
    }
}
