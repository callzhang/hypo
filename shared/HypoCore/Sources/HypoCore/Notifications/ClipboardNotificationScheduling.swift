import Foundation

@MainActor
public protocol ClipboardNotificationHandling: AnyObject {
    func handleNotificationCopy(for id: UUID)
    func handleNotificationDelete(for id: UUID)
    func handleNotificationClick(for id: UUID)
}

@MainActor
public protocol ClipboardNotificationScheduling: AnyObject, Sendable {
    func configure(handler: ClipboardNotificationHandling)
    func requestAuthorizationIfNeeded()
    func deliverNotification(for entry: ClipboardEntry)
    func deliverStatusNotification(deviceId: String, title: String, body: String)
}
