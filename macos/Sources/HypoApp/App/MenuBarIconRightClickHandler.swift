#if canImport(AppKit)
import AppKit
import SwiftUI

// Global reference to right-click menu so event monitors can access it
private var globalRightClickMenu: NSMenu?

/// Handles right-click menu for the menu bar icon by accessing the underlying NSStatusItem
struct MenuBarIconRightClickHandler: NSViewRepresentable {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    private let logger = HypoLogger(category: "MenuBarIconRightClickHandler")
    
    // Store event monitors to prevent deallocation
    private static var eventMonitors: [Any] = []
    // Track if monitors have been set up to prevent duplicates
    private static var monitorsSetup = false
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        
        // Set up right-click menu immediately and also with delays to catch different timing
        self.setupRightClickMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.setupRightClickMenu()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.setupRightClickMenu()
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed
    }
    
    private func setupRightClickMenu() {
        logger.info("🔧 Setting up right-click menu for menu bar icon")
        
        // Create the right-click menu
        let menu = NSMenu()
        
        // Version (disabled)
        let baseVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        
        // Determine build configuration (Debug or Release) by checking bundle path
        // Release builds use HypoApp-release.app, debug builds use HypoApp.app
        let bundlePath = Bundle.main.bundlePath
        let buildConfig = bundlePath.contains("-release") ? "Release" : "Debug"
        
        let versionString = "Version \(baseVersion) \(buildConfig)"
        let versionItem = NSMenuItem(title: versionString, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Show Clipboard (alt+v)
        let showHistoryItem = NSMenuItem(
            title: "Show Clipboard (alt+v)",
            action: #selector(MenuActionTarget.showHistory),
            keyEquivalent: "v"
        )
        showHistoryItem.keyEquivalentModifierMask = [.option]
        showHistoryItem.target = MenuActionTarget.shared
        MenuActionTarget.shared.showHistoryAction = {
            NSLog("📋 [Right-click menu] Show Clipboard√ selected")
            // Save frontmost app before showing (right-click menu may have activated Hypo)
            HistoryPopupPresenter.shared.saveFrontmostAppBeforeActivation()
            if let viewModel = AppContext.shared.historyViewModel {
                HistoryPopupPresenter.shared.show(with: viewModel)
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
            NSLog("🚪 [Right-click menu] Exit selected")
            NSApplication.shared.terminate(nil)
        }
        menu.addItem(quitItem)
        
        // Try multiple approaches to attach the menu
        // Approach 1: Find and attach directly to status item button
        attachMenuToStatusItem(menu: menu)
        
        // Approach 2: Monitor right-click events globally (fallback)
        setupGlobalRightClickMonitor(menu: menu)
    }
    
    private func attachMenuToStatusItem(menu: NSMenu) {
        // Try to find the status item by searching through status bar
        // MenuBarExtra creates an NSStatusItem, we need to find it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Search through status items to find ours
            // Since we can't directly access MenuBarExtra's status item,
            // we'll search for the button in status bar windows
            self.findStatusItemButtonAndAttachMenu(menu: menu)
        }
    }
    
    private func findStatusItemButtonAndAttachMenu(menu: NSMenu) {
        // Search through all windows to find status bar windows
        for window in NSApplication.shared.windows {
            if window.className.contains("NSStatusBarWindow") {
                // Found a status bar window, search for the button
                if let contentView = window.contentView {
                    self.attachMenuToButton(in: contentView, menu: menu)
                }
            }
        }
        
        // Also try again after a delay in case windows aren't ready yet
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for window in NSApplication.shared.windows {
                if window.className.contains("NSStatusBarWindow") {
                    if let contentView = window.contentView {
                        self.attachMenuToButton(in: contentView, menu: menu)
                    }
                }
            }
        }
    }
    
    private func attachMenuToButton(in view: NSView, menu: NSMenu) {
        // Recursively search for buttons
        if view is NSButton {
            // Found a button - event monitors will handle right-click
            logger.info("✅ Found status item button, event monitors will handle right-click")
            return
        }
        
        // Recursively search subviews
        for subview in view.subviews {
            attachMenuToButton(in: subview, menu: menu)
        }
    }
    
    private func setupGlobalRightClickMonitor(menu: NSMenu) {
        // Prevent duplicate setup
        guard !Self.monitorsSetup else {
            logger.info("⚠️ Event monitors already set up, skipping")
            // Update menu reference in case it changed
            globalRightClickMenu = menu
            return
        }
        
        // Store menu globally for access from monitors
        globalRightClickMenu = menu
        
        // Global monitor - works even when app is not active
        // Note: This requires accessibility permissions, but will work when app is active
        // This is critical for right-click to work without left-clicking first
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown], handler: { event in
            guard let menu = globalRightClickMenu else { return }
            // Check if click is in status bar area (top of screen)
            let location = NSEvent.mouseLocation
            let screenFrame = NSScreen.main?.frame ?? .zero
            // Status bar is at the top ~25 pixels
            if location.y > screenFrame.height - 25 {
                // Check if any status bar window contains this point
                for window in NSApplication.shared.windows {
                    if window.className.contains("NSStatusBarWindow") {
                        // Convert screen coordinates to window coordinates
                        let windowFrame = window.frame
                        // Check if location is within window bounds
                        if windowFrame.contains(location) {
                            // Show menu at mouse location
                            DispatchQueue.main.async {
                                menu.popUp(positioning: nil, at: location, in: nil)
                            }
                            break
                        }
                    }
                }
            }
        }) {
            Self.eventMonitors.append(globalMonitor)
        }
        
        // Local monitor - works when app is active (more reliable, lower latency)
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown], handler: { event in
            guard let menu = globalRightClickMenu else { return event }
            // Check if this is a right-click on a status bar window
            if let window = event.window,
               window.className.contains("NSStatusBarWindow") {
                let location = NSEvent.mouseLocation
                menu.popUp(positioning: nil, at: location, in: nil)
                return nil // Consume the event
            }
            return event
        }) {
            Self.eventMonitors.append(localMonitor)
        }
        
        Self.monitorsSetup = true
        logger.info("✅ Right-click event monitors set up (global + local)")
    }
    
}

/// Target object for menu actions (since @objc methods can't be in structs)
class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()
    
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
