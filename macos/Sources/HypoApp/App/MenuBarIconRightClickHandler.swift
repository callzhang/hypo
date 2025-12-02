#if canImport(AppKit)
import AppKit
import SwiftUI

/// Handles right-click menu for the menu bar icon by accessing the underlying NSStatusItem
struct MenuBarIconRightClickHandler: NSViewRepresentable {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    private let logger = HypoLogger(category: "MenuBarIconRightClickHandler")
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        
        // Set up right-click menu after MenuBarExtra creates the status item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.setupRightClickMenu()
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed
    }
    
    private func setupRightClickMenu() {
        logger.info("🔧 Setting up right-click menu for menu bar icon")
        
        // Find the NSStatusItem created by MenuBarExtra
        // MenuBarExtra creates a status item, we need to find it and add a menu
        // Create the right-click menu
        let menu = NSMenu()
        
        // Version (disabled)
        let versionString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let versionItem = NSMenuItem(title: "Version \(versionString)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Show Clipboard
        let showHistoryItem = NSMenuItem(
            title: "Show Clipboard",
            action: #selector(MenuActionTarget.showHistory),
            keyEquivalent: ""
        )
        showHistoryItem.target = MenuActionTarget.shared
        MenuActionTarget.shared.showHistoryAction = {
            NSLog("📋 [Right-click menu] Show Clipboard selected")
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
        
        // Monitor right-click events on status bar windows
        // When a right-click is detected on a status bar window, show our menu
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
            // Check if this is a right-click on a status bar window
            if let window = event.window,
               window.className.contains("NSStatusBarWindow") {
                // Show menu at mouse location
                let location = NSEvent.mouseLocation
                menu.popUp(positioning: nil, at: location, in: nil)
                return nil // Consume the event
            }
            return event
        }
        
        // Also try to directly attach menu to status item button if we can find it
        findAndAttachMenuToStatusItem(menu: menu)
    }
    
    private func findAndAttachMenuToStatusItem(menu: NSMenu) {
        // Try to find the status item by searching through status bar windows
        // This is a workaround since MenuBarExtra doesn't expose the NSStatusItem directly
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Search through all windows to find status bar windows
            for window in NSApplication.shared.windows {
                if window.className.contains("NSStatusBarWindow") {
                    // Found a status bar window, try to find the button
                    if let contentView = window.contentView {
                        self.findButtonAndAttachMenu(in: contentView, menu: menu)
                    }
                }
            }
        }
    }
    
    private func findButtonAndAttachMenu(in view: NSView, menu: NSMenu) {
        // Recursively search for buttons in the view hierarchy
        if view is NSButton {
            // Found a button - set up right-click handling
            // We can't directly set a menu on the button, but we can override mouseDown
            // For now, the event monitor approach should work
        }
        
        // Recursively search subviews
        for subview in view.subviews {
            findButtonAndAttachMenu(in: subview, menu: menu)
        }
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
