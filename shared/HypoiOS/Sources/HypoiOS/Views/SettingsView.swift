import SwiftUI
import UIKit
import UserNotifications
import HypoCore

public struct SettingsView: View {
    @State private var notificationStatus: String = "Checking…"

    private let deviceName: String
    private let deviceId: String

    public init(deviceName: String, deviceId: String) {
        self.deviceName = deviceName
        self.deviceId = deviceId
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("This device") {
                    LabeledContent("Name", value: deviceName)
                    LabeledContent("ID", value: String(deviceId.prefix(8)))
                }

                Section("Permissions") {
                    LabeledContent("Notifications", value: notificationStatus)
                    // iOS exposes no API for reading local network permission,
                    // so this can only explain and offer a way out. Denying it
                    // makes Bonjour fail silently, with no error anywhere, so
                    // saying nothing would leave LAN sync looking simply broken.
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
            }
            .navigationTitle("Settings")
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationStatus = switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: "Granted"
                case .denied: "Denied — background delivery will not work"
                case .notDetermined: "Not requested"
                @unknown default: "Unknown"
                }
            }
        }
    }
}
