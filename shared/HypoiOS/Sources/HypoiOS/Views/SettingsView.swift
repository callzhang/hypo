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
                notificationStatus = await Self.notificationStatusText()
            }
        }
    }
}
