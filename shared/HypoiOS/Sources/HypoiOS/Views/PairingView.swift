import SwiftUI
import HypoCore

/// Pairing, shaped like Android's: pick how you want to pair first, then see
/// only that flow.
///
/// The previous version put both halves of a mutually exclusive choice on one
/// screen — request a code *and* enter a code, with a Reset button that did
/// nothing yet — and offered no way to pair with a device already visible on
/// the network.
public struct PairingView: View {
    public enum Mode: String, CaseIterable {
        case lan = "LAN"
        case code = "Code"
    }

    /// Which half of code pairing the user chose. Neither is shown until they
    /// pick, because showing both is what made this confusing.
    private enum CodeStep {
        case choosing
        case showing
        case entering
    }

    @ObservedObject private var viewModel: RemotePairingViewModel
    @ObservedObject private var claimViewModel: ClaimPairingCodeViewModel
    @ObservedObject private var lanViewModel: LanPairingViewModel
    private let relayHint: URL?
    private let onPairOverLan: (DiscoveredPeer) -> Void

    @State private var mode: Mode = .lan
    @State private var codeStep: CodeStep = .choosing

    public init(
        viewModel: RemotePairingViewModel,
        claimViewModel: ClaimPairingCodeViewModel,
        lanViewModel: LanPairingViewModel,
        relayHint: URL?,
        onPairOverLan: @escaping (DiscoveredPeer) -> Void
    ) {
        self.viewModel = viewModel
        self.claimViewModel = claimViewModel
        self.lanViewModel = lanViewModel
        self.relayHint = relayHint
        self.onPairOverLan = onPairOverLan
    }

    public var body: some View {
        VStack(spacing: 20) {
            Picker("How to pair", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            switch mode {
            case .lan: lanContent
            case .code: codeContent
            }

            Spacer(minLength: 0)
        }
        .padding(.top)
        .navigationTitle("Pair a device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { lanViewModel.startDiscovery() }
        .onDisappear { lanViewModel.stopDiscovery() }
        .onChange(of: mode) { _, newMode in
            // One flow at a time, so leaving a mode abandons whatever it had
            // started rather than leaving it running out of sight.
            if newMode == .lan {
                viewModel.reset()
                claimViewModel.reset()
                codeStep = .choosing
            } else {
                lanViewModel.stopDiscovery()
            }
        }
    }

    // MARK: - Nearby devices

    @ViewBuilder
    private var lanContent: some View {
        switch lanViewModel.state {
        case .discovering:
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking for devices…")
                Text("Both devices need to be on the same network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)

        case .found(let peers) where peers.isEmpty:
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No devices found")
                Text("Make sure Hypo is open on the other device and both are on the same network. If that is right, try the Code tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 40)

        case .found(let peers):
            List {
                Section("Nearby devices") {
                    ForEach(peers, id: \.serviceName) { peer in
                        Button {
                            onPairOverLan(peer)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.serviceName)
                                        .foregroundStyle(.primary)
                                    Text(peer.endpoint.host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if lanViewModel.isPaired(peer) {
                                    Text("Paired").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)

        case .pairing(let name):
            VStack(spacing: 12) {
                ProgressView()
                Text("Pairing with \(name)…")
            }
            .padding(.top, 40)

        case .paired(let name):
            successView(deviceName: name) { lanViewModel.reset() }

        case .failed(let message):
            failureView(message) { lanViewModel.reset() }
        }
    }

    // MARK: - Pairing code

    @ViewBuilder
    private var codeContent: some View {
        if case .completed = viewModel.state {
            successView(deviceName: nil) {
                viewModel.reset()
                codeStep = .choosing
            }
        } else if case .completed = claimViewModel.state {
            successView(deviceName: nil) {
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

    private var visibleCode: String? {
        switch viewModel.state {
        case .displaying(let code, _), .awaitingChallenge(let code, _):
            return code
        default:
            return nil
        }
    }
}
