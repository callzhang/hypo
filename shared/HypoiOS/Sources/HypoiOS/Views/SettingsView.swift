import SwiftUI
import UIKit
import UserNotifications
import HypoCore

/// Pushed from the gear in the history screen's top row. Mirrors the Android
/// settings screen, minus the sections that are Android platform concerns
/// (battery optimisation, SMS permission, accessibility service) and plus the
/// local network row iOS needs.
public struct SettingsView: View {
    private let context: HypoiOSContext
    @ObservedObject private var transportManager: TransportManager
    private let pairingViewModel: RemotePairingViewModel
    private let claimViewModel: ClaimPairingCodeViewModel
    private let lanViewModel: LanPairingViewModel

    @State private var notificationStatus: String = "Checking…"
    @State private var historyLimit: Double = 200

    public init(
        context: HypoiOSContext,
        pairingViewModel: RemotePairingViewModel,
        claimViewModel: ClaimPairingCodeViewModel,
        lanViewModel: LanPairingViewModel
    ) {
        self.context = context
        self.transportManager = context.transportManager
        self.pairingViewModel = pairingViewModel
        self.claimViewModel = claimViewModel
        self.lanViewModel = lanViewModel
    }

    public var body: some View {
        List {
            Section("Connection") {
                LabeledContent("Status") {
                    Label {
                        Text(connectionDescription)
                    } icon: {
                        Image(systemName: connectionSymbol)
                            .foregroundStyle(connectionTint)
                    }
                    .font(.callout)
                }
            }

            Section("This device") {
                LabeledContent("Name", value: context.identity.deviceName)
                LabeledContent("ID", value: String(context.identity.deviceIdString.prefix(8)))
            }

            Section("Devices") {
                if transportManager.pairedDevices.isEmpty {
                    Text("No paired devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transportManager.pairedDevices) { device in
                        LabeledContent {
                            let state = status(of: device)
                            Text(state.label)
                                .font(.caption)
                                .foregroundStyle(state.tint)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(detail(of: device))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Unpair", role: .destructive) {
                                unpair(device)
                            }
                        }
                        .accessibilityIdentifier("PairedDevice-\(device.name)")
                    }
                }

                // Devices found on this network that are not paired yet, listed
                // here rather than behind a separate screen: this section is
                // already about devices, and a device you can see is the
                // shortest path to pairing with it. Typing a code is the
                // fallback for devices that cannot see each other.
                ForEach(nearbyUnpaired, id: \.serviceName) { peer in
                    Button {
                        lanViewModel.pair(with: peer)
                    } label: {
                        LabeledContent {
                            Text(pairingLabel(for: peer))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.serviceName)
                                    .foregroundStyle(.primary)
                                Text("On this network")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isPairing)
                    .accessibilityIdentifier("NearbyDevice-\(peer.serviceName)")
                }

                if case .failed(let message) = lanViewModel.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // Shown only once discovery has been empty for a while, which
                // is the one symptom a denied local network permission
                // produces. iOS offers no way to ask whether it was denied,
                // and a denial raises no error — Bonjour just returns nothing
                // forever. Saying this unprompted would be noise; saying it
                // exactly when the symptom appears is a diagnosis.
                if lanViewModel.foundNothingForAWhile {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No devices found on this network", systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("If your other device is on this network and running Hypo, iOS may have denied local network access. Sync still works through the relay, just slower.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.caption)
                    }
                    .accessibilityIdentifier("LanDiscoveryHint")
                }

                NavigationLink("Pair with code") {
                    PairingView(
                        viewModel: pairingViewModel,
                        claimViewModel: claimViewModel,
                        relayHint: transportManager.pairingParameters().relayHint
                    )
                }
            }

            Section("History") {
                VStack(alignment: .leading) {
                    LabeledContent("Keep", value: "\(Int(historyLimit)) items")
                    // 20…500 in steps of 10, the same range Android uses.
                    Slider(value: $historyLimit, in: 20...500, step: 10)
                        .onChange(of: historyLimit) { _, newValue in
                            Task { await context.historyViewModel.updateLimit(Int(newValue)) }
                        }
                }
            }

            Section("Permissions") {
                LabeledContent("Notifications", value: notificationStatus)
                // iOS exposes no API for reading local network permission, so
                // this can only explain and offer a way out. Denying it makes
                // Bonjour fail silently, with no error anywhere.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local network")
                    Text("If LAN sync never connects, iOS may have denied local network access. Grant it in Settings › Privacy & Security › Local Network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Self.appVersion)
            }
        }
        .navigationTitle("Settings")
        // Discovery runs while this screen is open, because the nearby list
        // lives here now rather than behind the pairing screen.
        .onAppear { lanViewModel.startDiscovery() }
        .onDisappear { lanViewModel.stopDiscovery() }
        .task {
            notificationStatus = await Self.notificationStatusText()
            historyLimit = Double(await context.historyStore.limit())
        }
    }

    /// What is actually known about a device, rather than a bare online flag.
    ///
    /// isOnline only becomes true once a connection is established, so a device
    /// sitting right there on the network reads as "Offline" until something
    /// has been sent — which is both true and useless. Bonjour already knows it
    /// is nearby; say so.
    /// Discovered peers that are not paired yet.
    ///
    /// A device already in the paired list above would otherwise appear twice,
    /// once as something to manage and once as something to pair with.
    private var nearbyUnpaired: [DiscoveredPeer] {
        guard case .found(let peers) = lanViewModel.state else { return [] }
        let paired = Set(transportManager.pairedDevices.map { $0.id.lowercased() })
        return peers.filter { peer in
            guard let id = peer.endpoint.metadata["device_id"]?.lowercased() else { return true }
            return !paired.contains(id)
        }
    }

    private var isPairing: Bool {
        if case .pairing = lanViewModel.state { return true }
        return false
    }

    private func pairingLabel(for peer: DiscoveredPeer) -> String {
        if case .pairing(let name) = lanViewModel.state, name == peer.serviceName {
            return "Pairing…"
        }
        return "Pair"
    }

    /// The address when it is known, otherwise when it was last seen.
    ///
    /// This used to show `device.platform`, which is always "Unknown": nothing
    /// in the handshake carries a platform — the challenge has an id, a name
    /// and keys, and the Bonjour record has no platform field either — so every
    /// row said the same useless word. Android's device row shows the address
    /// or a last-seen time for exactly this reason.
    private func detail(of device: PairedDevice) -> String {
        if let host = device.bonjourHost, let port = device.bonjourPort {
            return "\(host):\(port)"
        }
        if let host = device.bonjourHost {
            return host
        }
        return "Last seen \(device.lastSeen.formatted(.relative(presentation: .named)))"
    }

    private func status(of device: PairedDevice) -> (label: String, tint: Color) {
        if device.isOnline { return ("Connected", .green) }
        let onThisNetwork = transportManager.lanDiscoveredPeers().contains { peer in
            peer.endpoint.metadata["device_id"]?.lowercased() == device.id.lowercased()
        }
        if onThisNetwork { return ("On this network", .secondary) }
        return ("Not reachable", .secondary)
    }

    /// Forgets a device: key first, the way Android does it.
    ///
    /// A device left in the list with no key cannot decrypt anything it is
    /// sent, which looks like a broken peer rather than one that was removed.
    private func unpair(_ device: PairedDevice) {
        context.unpair(device)
    }

    // The same symbols and colours the macOS menu bar uses, so both clients
    // describe one connection the same way.
    private var connectionSymbol: String {
        switch transportManager.connectionState {
        case .disconnected: return "cloud.slash.fill"
        case .connectingLan, .connectingCloud: return "arrow.triangle.2.circlepath"
        case .connectedLan: return "wifi"
        case .connectedCloud: return "cloud.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var connectionTint: Color {
        switch transportManager.connectionState {
        case .disconnected: return .gray
        case .connectingLan, .connectingCloud: return .orange
        case .connectedLan: return .green
        case .connectedCloud: return .blue
        case .error: return .red
        }
    }

    private var connectionDescription: String {
        switch transportManager.connectionState {
        case .disconnected: return "Disconnected"
        case .connectingLan, .connectingCloud: return "Connecting…"
        case .connectedLan: return "LAN"
        case .connectedCloud: return "Connected"
        case .error: return "Disconnected"
        }
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    /// Reads the authorization status without letting UNNotificationSettings
    /// cross an isolation boundary.
    ///
    /// `await ...notificationSettings()` returns the settings object itself,
    /// which is not Sendable. Xcode 26.5 accepts that; the CI toolchain rejects
    /// it, which is how this was found. Mapping to a String inside the
    /// completion handler means only a Sendable value is ever resumed, and it
    /// does not depend on which toolchain compiles it.
    private static func notificationStatusText() async -> String {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let text: String
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    text = "Granted"
                case .denied:
                    text = "Denied — background delivery will not work"
                case .notDetermined:
                    text = "Not requested"
                @unknown default:
                    text = "Unknown"
                }
                continuation.resume(returning: text)
            }
        }
    }
}
