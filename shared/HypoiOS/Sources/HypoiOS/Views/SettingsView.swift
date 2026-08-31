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
                LabeledContent("Status", value: connectionDescription)
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
                            Text(device.isOnline ? "Online" : "Offline")
                                .foregroundStyle(device.isOnline ? .green : .secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.platform)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                NavigationLink("Pair a device") {
                    PairingView(
                        viewModel: pairingViewModel,
                        claimViewModel: claimViewModel,
                        lanViewModel: lanViewModel,
                        relayHint: transportManager.pairingParameters().relayHint,
                        onPairOverLan: { peer in lanViewModel.pair(with: peer) }
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
        .task {
            notificationStatus = await Self.notificationStatusText()
            historyLimit = Double(await context.historyStore.limit())
        }
    }

    private var connectionDescription: String {
        switch transportManager.connectionState {
        case .disconnected: return "Disconnected"
        case .connectingLan: return "Connecting over LAN…"
        case .connectedLan: return "Connected over LAN"
        case .connectingCloud: return "Connecting to relay…"
        case .connectedCloud: return "Connected via relay"
        case .error(let message): return message
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
