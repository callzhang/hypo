import Foundation
import UserNotifications
import HypoCore

/// iOS implementation of ClipboardNotificationScheduling.
///
/// Phase 2 posts local notifications while the app is running. Phase 4 adds
/// APNs-driven delivery through a notification service extension, which needs
/// a paid developer account.
public final class UserNotificationScheduler: ClipboardNotificationScheduling, @unchecked Sendable {
    /// nil when there is no notification centre to talk to.
    /// `UNUserNotificationCenter.current()` raises outside an app bundle,
    /// because it resolves the running process to an installed application and
    /// a plain test bundle is not one. Tests pass nil explicitly; the default
    /// argument is only evaluated when the app builds this for real.
    private let center: UNUserNotificationCenter?
    private weak var handler: ClipboardNotificationHandling?

    public init(center: UNUserNotificationCenter? = .current()) {
        self.center = center
    }

    public func configure(handler: ClipboardNotificationHandling) {
        self.handler = handler
    }

    public func requestAuthorizationIfNeeded() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func deliverNotification(for entry: ClipboardEntry) {
        let content = UNMutableNotificationContent()
        content.title = "Clipboard received"
        content.body = entry.content.previewDescription
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: entry.id.uuidString,
            content: content,
            trigger: nil
        )
        center?.add(request, withCompletionHandler: nil)
    }

    public func deliverStatusNotification(deviceId: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: "status-\(deviceId)",
            content: content,
            trigger: nil
        )
        center?.add(request, withCompletionHandler: nil)
    }
}
