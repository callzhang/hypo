#if canImport(UserNotifications)
import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public protocol ClipboardNotificationHandling: AnyObject {
    func handleNotificationCopy(for id: UUID)
    func handleNotificationDelete(for id: UUID)
}

public protocol ClipboardNotificationScheduling: AnyObject {
    func configure(handler: ClipboardNotificationHandling)
    func requestAuthorizationIfNeeded()
    func deliverNotification(for entry: ClipboardEntry)
}

public final class ClipboardNotificationController: NSObject, ClipboardNotificationScheduling {
    public static let shared = ClipboardNotificationController()

    private enum Constants {
        static let categoryIdentifier = "clipboard_entry"
        static let copyActionIdentifier = "clipboard_copy_again"
        static let deleteActionIdentifier = "clipboard_delete"
        static let authorizationRequestedKey = "clipboard_notifications_requested"
    }

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private weak var handler: ClipboardNotificationHandling?
    private let fileManager: FileManager

    public init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.center = center
        self.defaults = defaults
        self.fileManager = fileManager
        super.init()
    }

    public func configure(handler: ClipboardNotificationHandling) {
        self.handler = handler
        center.delegate = self
        registerCategories()
    }

    public func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            if settings.authorizationStatus == .notDetermined || !self.defaults.bool(forKey: Constants.authorizationRequestedKey) {
                self.center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                    self.defaults.set(true, forKey: Constants.authorizationRequestedKey)
                }
            }
        }
    }

    public func deliverNotification(for entry: ClipboardEntry) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
#if canImport(AppKit)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !NSApplication.shared.isActive else { return }
                self.enqueueNotification(for: entry)
            }
#else
            self.enqueueNotification(for: entry)
#endif
        }
    }

    private func enqueueNotification(for entry: ClipboardEntry) {
        let identifier = entry.id.uuidString
        let content = buildContent(for: entry)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(request, withCompletionHandler: nil)
    }

    private func registerCategories() {
        let copy = UNNotificationAction(
            identifier: Constants.copyActionIdentifier,
            title: "Copy Again",
            options: []
        )
        let delete = UNNotificationAction(
            identifier: Constants.deleteActionIdentifier,
            title: "Delete",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Constants.categoryIdentifier,
            actions: [copy, delete],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    private func buildContent(for entry: ClipboardEntry) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = entry.content.title
        content.subtitle = "From \(entry.originDeviceId)"
        content.body = entry.previewText
        content.sound = .default
        content.categoryIdentifier = Constants.categoryIdentifier
        content.userInfo = ["entryID": entry.id.uuidString]

        if let attachment = attachment(for: entry) {
            content.attachments = [attachment]
        }

        return content
    }

    private func attachment(for entry: ClipboardEntry) -> UNNotificationAttachment? {
        guard case .image(let metadata) = entry.content else { return nil }
        guard let data = metadata.thumbnail ?? metadata.data, !data.isEmpty else { return nil }

        let fileExtension = (metadata.format.isEmpty ? "png" : metadata.format.lowercased())
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent("clipboard-thumbnail-\(UUID().uuidString).\(fileExtension)")

        do {
            try data.write(to: tempURL, options: .atomic)
            return try UNNotificationAttachment(identifier: "thumbnail", url: tempURL, options: nil)
        } catch {
            return nil
        }
    }
}

extension ClipboardNotificationController: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier

        defer { completionHandler() }

        guard let id = UUID(uuidString: identifier) else { return }

        switch actionIdentifier {
        case Constants.copyActionIdentifier, UNNotificationDefaultActionIdentifier:
            Task { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.handler?.handleNotificationCopy(for: id)
                }
            }
        case Constants.deleteActionIdentifier:
            Task { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.handler?.handleNotificationDelete(for: id)
                }
            }
        default:
            break
        }
    }
}

extension UNUserNotificationCenter: @unchecked Sendable {}

#endif
