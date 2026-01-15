#if canImport(UserNotifications)
import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os
#endif

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

@MainActor
public final class ClipboardNotificationController: NSObject, ClipboardNotificationScheduling {
    public static let shared: any ClipboardNotificationScheduling = ClipboardNotificationController() ?? NoOpNotificationController()

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

    public init?(
        center: UNUserNotificationCenter? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        // Use provided center or try to get current, but handle case where bundle isn't available (debug builds)
        let notificationCenter: UNUserNotificationCenter
        if let providedCenter = center {
            notificationCenter = providedCenter
        } else {
            // Check if we're in a proper app bundle before using .current()
            // UNUserNotificationCenter.current() requires a proper app bundle
            // When running from .build directory, Bundle.main.bundleURL won't end in .app
            let bundleURL = Bundle.main.bundleURL
            if bundleURL.pathExtension == "app" || bundleURL.path.contains(".app/") {
                // We're in a proper app bundle, safe to use .current()
                notificationCenter = .current()
                
                // Verify app icon is accessible
                #if canImport(AppKit)
                #if canImport(os)
                let logger = HypoLogger(category: "ClipboardNotificationController")
                if let iconFile = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
                    logger.debug("📱 [ClipboardNotificationController] Icon file from Info.plist: \(iconFile)")
                    if let iconPath = Bundle.main.path(forResource: iconFile, ofType: "icns") {
                        logger.debug("✅ [ClipboardNotificationController] Icon file found at: \(iconPath)")
                    } else if let iconPath = Bundle.main.path(forResource: iconFile.replacingOccurrences(of: ".icns", with: ""), ofType: "icns") {
                        logger.debug("✅ [ClipboardNotificationController] Icon file found (without extension) at: \(iconPath)")
                    } else {
                        logger.warning("⚠️ [ClipboardNotificationController] Icon file not found: \(iconFile)")
                    }
                } else {
                    logger.warning("⚠️ [ClipboardNotificationController] CFBundleIconFile not set in Info.plist")
                }
                
                // Check if NSApplication can access the icon
                if let appIcon = NSApplication.shared.applicationIconImage {
                    logger.debug("✅ [ClipboardNotificationController] NSApplication.applicationIconImage accessible: \(appIcon.size)")
                } else {
                    logger.warning("⚠️ [ClipboardNotificationController] NSApplication.applicationIconImage is nil")
                }
                #endif
                #endif
            } else {
                // For debug builds running from .build directory, we can't use .current()
                // Return nil to indicate notifications aren't available
                return nil
            }
        }
        
        self.center = notificationCenter
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
            let status = settings.authorizationStatus
            let hasRequested = self.defaults.bool(forKey: Constants.authorizationRequestedKey)
            
            #if canImport(os)
            let logger = HypoLogger(category: "ClipboardNotificationController")
            logger.info("📢 Notification authorization status: \(String(describing: status)), hasRequested: \(hasRequested)")
            #endif
            
            if status == .notDetermined || !hasRequested {
                #if canImport(os)
                logger.info("📢 Requesting notification authorization...")
                #endif
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    #if canImport(os)
                    let logger = HypoLogger(category: "ClipboardNotificationController")
                    if let error = error {
                        logger.error("❌ Notification authorization error: \(error.localizedDescription)")
                    } else {
                        logger.info("✅ Notification authorization granted: \(granted)")
                    }
                    #endif
                    self.defaults.set(true, forKey: Constants.authorizationRequestedKey)
                }
            } else if status == .denied {
                Task { @MainActor in
                    self.showNotificationPermissionAlert()
                }
                #if canImport(os)
                let logger = HypoLogger(category: "ClipboardNotificationController")
                logger.warning("⚠️ Notification permission denied. User must enable in System Settings → Notifications → Hypo")
                #endif
                // Don't show popup alert - user can check status in Settings view
            }
        }
    }

    public func deliverNotification(for entry: ClipboardEntry) {
        #if canImport(os)
        let logger = HypoLogger(category: "ClipboardNotificationController")
        logger.debug("📢 [ClipboardNotificationController] deliverNotification called for entry: \(entry.previewText.prefix(50))")
        #endif
        
        center.getNotificationSettings { [weak self] settings in
            guard let self else {
                #if canImport(os)
                let logger = HypoLogger(category: "ClipboardNotificationController")
                logger.warning("⚠️ [ClipboardNotificationController] Self deallocated in getNotificationSettings callback")
                #endif
                return
            }
            
            #if canImport(os)
            let logger = HypoLogger(category: "ClipboardNotificationController")
            #endif
            
            let status = settings.authorizationStatus
            #if canImport(os)
            logger.debug("📢 [ClipboardNotificationController] Authorization status: \(String(describing: status))")
            #endif
            
            guard status == .authorized || status == .provisional else {
                #if canImport(os)
                logger.warning("⚠️ [ClipboardNotificationController] Cannot deliver notification: authorization status is \(String(describing: status))")
                #endif
                return
            }
            
            // For menu bar apps, we always show notifications regardless of app active state
            // Menu bar apps are background apps and should notify users of incoming clipboard items
            #if canImport(os)
            logger.debug("✅ [ClipboardNotificationController] Enqueuing notification")
            #endif
            Task { @MainActor [weak self] in
                self?.enqueueNotification(for: entry)
            }
        }
    }

    private func enqueueNotification(for entry: ClipboardEntry) {
        #if canImport(os)
        let logger = HypoLogger(category: "ClipboardNotificationController")
        logger.debug("📢 [ClipboardNotificationController] enqueueNotification: \(entry.previewText.prefix(50))")
        #endif
        
        let identifier = entry.id.uuidString
        let content = buildContent(for: entry)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)

        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(request) { error in
            #if canImport(os)
            let logger = HypoLogger(category: "ClipboardNotificationController")
            if let error = error {
                logger.error("❌ [ClipboardNotificationController] Failed to add notification: \(error.localizedDescription)")
            } else {
                logger.debug("✅ [ClipboardNotificationController] Notification added successfully")
            }
            #endif
        }
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
        // Title: device name (or fallback if not available)
        content.title = entry.originDeviceName ?? "Unknown Device"
        // Subtitle: [content type] readable timestamp
        let timestampString = formatTimestamp(entry.timestamp)
        content.subtitle = "[\(entry.content.title)] \(timestampString)"
        // Body: message content
        content.body = entry.previewText
        content.sound = .default
        content.categoryIdentifier = Constants.categoryIdentifier
        content.userInfo = ["entryID": entry.id.uuidString]

        // Only add image thumbnail attachment for image entries
        // The app icon on the left is automatically provided by macOS from the app bundle
        if let attachment = attachment(for: entry) {
            content.attachments = [attachment]
        }

        return content
    }
    
    public func deliverStatusNotification(deviceId: String, title: String, body: String) {
        #if canImport(os)
        let logger = HypoLogger(category: "ClipboardNotificationController")
        logger.debug("📢 [ClipboardNotificationController] deliverStatusNotification: title=\(title), body=\(body)")
        #endif
        
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            
            let status = settings.authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // Use a specific category or default
            // content.categoryIdentifier = ... 
            
            // Use a stable per-device identifier to coalesce status updates
            let identifier = "status-\(deviceId.lowercased())"
            
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            
            self.center.removeDeliveredNotifications(withIdentifiers: [identifier])
            self.center.removePendingNotificationRequests(withIdentifiers: [identifier])
            self.center.add(request) { error in
                #if canImport(os)
                if let error = error {
                    logger.error("❌ [ClipboardNotificationController] Failed to add status notification: \(error.localizedDescription)")
                }
                #endif
            }
        }
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        let now = Date()
        
        // Check if it's today
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        
        // Check if it's yesterday
        if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
            return "Yesterday \(formatter.string(from: date))"
        }
        
        // Check if it's within the last week
        if let daysAgo = calendar.dateComponents([.day], from: date, to: now).day, daysAgo < 7 {
            formatter.dateFormat = "EEEE HH:mm"
            return formatter.string(from: date)
        }
        
        // Otherwise, show full date
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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

extension ClipboardNotificationController: @preconcurrency UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Always show notification even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    @MainActor
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
        case Constants.copyActionIdentifier:
            handler?.handleNotificationCopy(for: id)
        case UNNotificationDefaultActionIdentifier:
            handler?.handleNotificationClick(for: id)
        case Constants.deleteActionIdentifier:
            handler?.handleNotificationDelete(for: id)
        default:
            break
        }
    }
}

// Sendable conformance for SDK type – safe because UNUserNotificationCenter is a singleton reference type
extension UNUserNotificationCenter: @retroactive @unchecked Sendable {}

#if canImport(AppKit)
extension ClipboardNotificationController {
    @MainActor
    private func showNotificationPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Notification Permission Required"
        alert.informativeText = "Hypo needs notification permission to show you when clipboard items are synced from other devices.\n\nPlease enable notifications in System Settings → Notifications → Hypo"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Settings to Notifications
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
#endif

// No-op implementation for when notifications aren't available (debug builds)
@MainActor
final class NoOpNotificationController: NSObject, ClipboardNotificationScheduling {
    func configure(handler: ClipboardNotificationHandling) {}
    func requestAuthorizationIfNeeded() {}
    func deliverNotification(for entry: ClipboardEntry) {}
    func deliverStatusNotification(deviceId: String, title: String, body: String) {}
}

#endif
