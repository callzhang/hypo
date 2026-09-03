import Foundation
import UserNotifications
import HypoCore

/// iOS implementation of ClipboardNotificationScheduling.
///
/// Phase 2 posts local notifications while the app is running. Phase 4 adds
/// APNs-driven delivery through a notification service extension, which needs
/// a paid developer account.
public final class UserNotificationScheduler: ClipboardNotificationScheduling, @unchecked Sendable {
    private let explicitCenter: UNUserNotificationCenter?
    private weak var handler: ClipboardNotificationHandling?

    public init(center: UNUserNotificationCenter? = nil) {
        self.explicitCenter = center
    }

    /// nil when there is no notification centre to talk to.
    ///
    /// Resolved here rather than in a default argument. A default argument is
    /// evaluated at every call site that omits it, so `= .current()` still ran
    /// for anything building this without an explicit centre — including the
    /// app container that tests construct. `current()` raises an ObjC assertion
    /// outside an app bundle, and that raise is not something a Swift catch can
    /// hold, so it has to be avoided rather than handled: it took down the
    /// whole test process before a single test ran.
    private var center: UNUserNotificationCenter? {
        if let explicitCenter { return explicitCenter }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return .current()
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
