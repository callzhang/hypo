#if canImport(AppKit)
import AppKit
import SwiftUI

/// Manages right-click menu for the menu bar icon
/// This replaces the SwiftUI-based MenuBarIconRightClickHandler to ensure reliable
/// initialization at app launch, before any user interaction.
@MainActor
class MenuBarRightClickManager {
    static let shared = MenuBarRightClickManager()
    
    private let logger = HypoLogger(category: "MenuBarRightClickManager")
    private var eventMonitors: [Any] = []
    private var isSetup = false
    private var rightClickMenu: NSMenu?
    private weak var showHistoryItem: NSMenuItem?
    private var shortcutObserver: NSObjectProtocol?
    
    // Prevent external initialization
    nonisolated private init() {}
    
    func setup() {
        guard !isSetup else {
            logger.debug("ℹ️ MenuBarRightClickManager already set up, skipping")
            return
        }
        
        logger.info("🔧 Setting up MenuBarRightClickManager")
        
        // Create the menu
        let menu = createRightClickMenu()
        self.rightClickMenu = menu
        setupShortcutObserver()
        
        // Setup global/local event monitors immediately
        setupEventMonitors(menu: menu)
        
        // Also try to find and attach to the status item button directly
        // We do this with a few delays to catch the status item when it appears
        scheduleButtonAttachment(menu: menu)
        
        isSetup = true
    }
    
    private func createRightClickMenu() -> NSMenu {
        let menu = NSMenu()
        let shortcut = currentShowClipboardShortcut()
        
        // Version (disabled)
        let baseVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let buildConfig = Bundle.main.object(forInfoDictionaryKey: "HypoBuildConfiguration") as? String ?? "Debug"
        
        let versionString = "Version \(baseVersion) \(buildConfig)"
        let versionItem = NSMenuItem(title: versionString, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Show Clipboard (alt+v)
        let showHistoryItem = NSMenuItem(
            title: "Show Clipboard",
            action: #selector(MenuActionTarget.showHistory),
            keyEquivalent: shortcut?.keyEquivalent ?? ""
        )
        showHistoryItem.keyEquivalentModifierMask = shortcut?.eventModifierFlags ?? []
        showHistoryItem.target = MenuActionTarget.shared
        self.showHistoryItem = showHistoryItem
        
        // Configure actions
        MenuActionTarget.shared.showHistoryAction = {
            Task { @MainActor in
                NSLog("📋 [Right-click menu] Show Clipboard selected")
                // Save frontmost app before showing (right-click menu may have activated Hypo)
                HistoryPopupPresenter.shared.saveFrontmostAppBeforeActivation()
                if let viewModel = AppContext.shared.historyViewModel {
                    menu.cancelTracking()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    HistoryPopupPresenter.shared.show(with: viewModel)
                }
            }
        }
        menu.addItem(showHistoryItem)

        // Separator
        menu.addItem(NSMenuItem.separator())

        // Exit
        let quitItem = NSMenuItem(
            title: "Exit",
            action: #selector(MenuActionTarget.quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = MenuActionTarget.shared
        
        MenuActionTarget.shared.quitAction = {
            Task { @MainActor in
                NSLog("🚪 [Right-click menu] Exit selected")
                // Use delegate's requestQuit method to properly handle termination
                if let delegate = NSApplication.shared.delegate as? HypoAppDelegate {
                    delegate.requestQuit()
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        menu.addItem(quitItem)
        
        return menu
    }

    private func setupShortcutObserver() {
        if let observer = shortcutObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: .showClipboardShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawShortcut = notification.userInfo?["shortcut"] as? String ?? ""
            Task { @MainActor [weak self] in
                let shortcut = rawShortcut.isEmpty ? nil : KeyboardShortcut(defaultsValue: rawShortcut)
                self?.applyShortcut(shortcut)
            }
        }
    }

    private func currentShowClipboardShortcut() -> KeyboardShortcut? {
        if let rawShortcut = UserDefaults.standard.string(forKey: "show_clipboard_shortcut") {
            if rawShortcut.isEmpty {
                return nil
            }
            if let shortcut = KeyboardShortcut(defaultsValue: rawShortcut) {
                return shortcut
            }
        }
        return .defaultShowClipboard
    }

    private func applyShortcut(_ shortcut: KeyboardShortcut?) {
        showHistoryItem?.title = "Show Clipboard"
        showHistoryItem?.keyEquivalent = shortcut?.keyEquivalent ?? ""
        showHistoryItem?.keyEquivalentModifierMask = shortcut?.eventModifierFlags ?? []
    }
    
    private func setupEventMonitors(menu: NSMenu) {
        // Local monitor - works when app is active key application
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown], handler: { [weak self] event in
            return self?.handleRightClick(event: event, menu: menu)
        }) {
            eventMonitors.append(localMonitor)
        }
        
        logger.info("✅ Right-click event monitors set up")
    }
    
    private func handleRightClick(event: NSEvent, menu: NSMenu) -> NSEvent? {
        // Check if this is a right-click on a status bar window
        if let window = event.window,
           window.className.contains("NSStatusBarWindow") {
            logger.debug("🖱️ Detected right-click on status bar window via event monitor")
            let location = NSEvent.mouseLocation
            
            // Pop up the menu
            // We need to run this on the next runloop cycle to avoid blocking the event processing
            DispatchQueue.main.async {
                menu.popUp(positioning: nil, at: location, in: nil)
            }
            
            return nil // Consume the event
        }
        return event
    }
    
    private func scheduleButtonAttachment(menu: NSMenu) {
        // Try multiple times to find the status item button
        let delays = [0.1, 0.5, 1.0, 2.0, 5.0]
        
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.findStatusItemButtonAndAttachMenu(menu: menu)
            }
        }
    }
    
    private func findStatusItemButtonAndAttachMenu(menu: NSMenu) {
        // Search through all windows to find status bar windows
        var found = false
        for window in NSApplication.shared.windows {
            if window.className.contains("NSStatusBarWindow") {
                // Found a status bar window, search for the button
                if let contentView = window.contentView {
                    if attachMenuToButton(in: contentView, menu: menu) {
                        found = true
                    }
                }
            }
        }
        
        if found {
            // logger.debug("✅ Attached menu to status item button")
        }
    }
    
    @discardableResult
    private func attachMenuToButton(in view: NSView, menu: NSMenu) -> Bool {
        // Recursively search for buttons (NSStatusBarButton is a subclass of NSButton)
        if view is NSButton {
            // The event monitor handles right-click; MenuBarExtra(.window) handles left-click.
            // No need to override target/action here.
            return true
        }
        
        var found = false
        for subview in view.subviews {
            if attachMenuToButton(in: subview, menu: menu) {
                found = true
            }
        }
        return found
    }
}

/// Target object for menu actions (since @objc methods can't be in structs)
/// Kept here for compatibility with the new manager
@MainActor
class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()
    
    nonisolated override init() {
        super.init()
    }
    
    var showHistoryAction: (() -> Void)?
    var showSettingsAction: (() -> Void)?
    var quitAction: (() -> Void)?
    
    @objc func showHistory() {
        showHistoryAction?()
    }
    
    @objc func showSettings() {
        showSettingsAction?()
    }
    
    @objc func quitApp() {
        quitAction?()
    }
}
#endif
