#if canImport(AppKit)
import AppKit
import SwiftUI
import os.log
#if canImport(Carbon)
import Carbon
#endif

/// Custom NSPanel that allows keyboard input but doesn't actively steal focus
private class NonFocusStealingPanel: NSPanel {
    override var canBecomeKey: Bool {
        return true  // Allow window to become key window so search field can receive input
    }
    
    override var canBecomeMain: Bool {
        return false  // Window cannot become main window
    }
    
    // Override keyDown to handle ESC key and pass other events to super
    // ESC key is primarily handled via NSEvent local monitor, but we handle it here as fallback
    override func keyDown(with event: NSEvent) {
        // Handle ESC key (keyCode 53) to close window
        // If pinned, only dismiss if this window is the key window (focused)
        if event.keyCode == 53 {
            let presenter = HistoryPopupPresenter.shared
            if !presenter.pinned || (presenter.pinned && self.isKeyWindow) {
                presenter.hide()
            }
            return
        }
        // Pass other keyboard events to super so TextField can receive input
        super.keyDown(with: event)
    }
}

/// Custom NSView that cannot become first responder
private class NonFocusStealingView: NSView {
    override var acceptsFirstResponder: Bool {
        return false
    }
}

/// Presents the history view in a floating, centered window when the global hotkey fires.
@MainActor
final class HistoryPopupPresenter {
    static let shared = HistoryPopupPresenter()
    private let logger = HypoLogger(category: "HistoryPopupPresenter")
    nonisolated private init() {}

    private var window: NSPanel?
    private var isPinned: Bool = false  // Start unpinned - window can be dismissed by clicking outside
    private var globalClickMonitor: Any?
    private var escKeyMonitor: Any?
    private var previousFrontmostApp: NSRunningApplication?  // Save the app that was frontmost before showing window

    func show(with viewModel: ClipboardHistoryViewModel) {
        // Save the frontmost app before showing window (for focus restoration)
        // CRITICAL: Only update previousFrontmostApp when currentFrontmost is a valid non-Hypo app
        // When nil or Hypo, preserve the previous value to ensure focus restoration works correctly
        // This matches the logic in saveFrontmostAppBeforeActivation()
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        let hypoBundleId = Bundle.main.bundleIdentifier ?? "com.hypo.clipboard"
        
        // Only save if it's a valid non-Hypo application
        if let current = currentFrontmost, current.bundleIdentifier != hypoBundleId {
            previousFrontmostApp = current
        }
        
        DispatchQueue.main.async {
            Task { @MainActor in
                await viewModel.start()
                self.present(with: viewModel)
            }
        }
    }
    
    /// Save the frontmost app before activating Hypo (call this before NSApp.activate())
    func saveFrontmostAppBeforeActivation() {
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        let hypoBundleId = Bundle.main.bundleIdentifier ?? "com.hypo.clipboard"
        
        // Only save if it's not Hypo itself
        if let current = currentFrontmost, current.bundleIdentifier != hypoBundleId {
            previousFrontmostApp = currentFrontmost
        }
    }

    func hide() {
        DispatchQueue.main.async {
            guard let window = self.window, window.isVisible else { return }
            
            // Don't hide if window is pinned
            guard !self.isPinned else { return }
            
            // Restore focus to previous app when hiding (works for ESC key and click-outside)
            self.restorePreviousFocus()
            
            // Animate fade out
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                window.animator().alphaValue = 0.0
            }, completionHandler: {
                Task { @MainActor in
                    window.orderOut(nil)
                    window.alphaValue = 1.0  // Reset for next show
                    self.removeClickMonitor()
                    self.removeEscMonitor()  // Remove ESC key monitor
                }
            })
        }
    }

    var pinned: Bool { isPinned }

    func togglePinned() {
        isPinned.toggle()
        applyWindowLevel()
        updateClickMonitor()
    }

    private func applyWindowLevel() {
        guard let window else { return }
        applyWindowPresentation(for: window)
    }
    
    func hideAndRestoreFocus(completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            guard let window = self.window, window.isVisible else {
                // If window not visible, just restore focus and call completion
                self.restorePreviousFocus()
                completion()
                return
            }
            
            // If window is pinned, don't hide it - just restore focus and paste
            if self.isPinned {
                // Restore focus to the previous frontmost app before pasting
                self.restorePreviousFocus()
                // Small delay to ensure focus is restored before pasting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    completion()
                }
                return
            }
            
            // Remove monitors first
            self.removeClickMonitor()
            self.removeEscMonitor()  // Remove ESC key monitor
            
            // CRITICAL: Resign first responder to ensure no text field captures input
            // This prevents "paste into search bar" bug if window receives the event
            window.makeFirstResponder(nil)
            
            // Hide window immediately (no animation) for faster paste
            window.orderOut(nil)
            window.alphaValue = 1.0  // Reset for next show
            
            // CRITICAL: Restore focus to the previous frontmost app before pasting
            // This ensures the paste goes to the correct window
            self.restorePreviousFocus()
            
            // CRITICAL: Even though window doesn't steal focus, a visible window can still intercept
            // keyboard events. We must ensure the window is fully hidden before sending events.
            // Reduced delay from 0.2s to 0.05s for faster paste response
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                // Verify window is actually hidden before proceeding
                if window.isVisible {
                    self.logger.warning("⚠️ Window still visible after orderOut, forcing hide")
                    window.orderOut(nil)
                }
                
                // Verify focus was restored (with retries)
                self.checkFocusAndComplete(completion: completion, attempts: 5)
            }
        }
    }
    
    private func checkFocusAndComplete(completion: @escaping () -> Void, attempts: Int) {
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        let hypoBundleId = Bundle.main.bundleIdentifier ?? "com.hypo.clipboard"
        
        // If Hypo is NOT frontmost, we are good
        if let current = currentFrontmost, current.bundleIdentifier != hypoBundleId {
            logger.debug("✅ Focus restored to: \(current.localizedName ?? "unknown")")
            completion()
            return
        }
        
        // If we have an expected app, check if it's that one (even if bundle ID check was ambiguous)
        if let expected = previousFrontmostApp, let current = currentFrontmost {
            if current.processIdentifier == expected.processIdentifier {
                 logger.debug("✅ Focus restored to expected app: \(current.localizedName ?? "unknown")")
                 completion()
                 return
            }
        }
        
        // If Hypo is still frontmost and we have attempts left, wait and retry
        if attempts > 0 {
            logger.debug("⚠️ Hypo still frontmost, waiting for focus transfer... (\(attempts) left)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.checkFocusAndComplete(completion: completion, attempts: attempts - 1)
            }
            return
        }
        
        // No attempts left, proceed anyway
        logger.warning("⚠️ Failed to restore focus after retries. Proceeding anyway.")
        completion()
    }
    
    private func restorePreviousFocus() {
        guard let previousApp = previousFrontmostApp else {
            logger.debug("ℹ️ No previous app to restore focus to")
            return
        }
        
        // Activate the previous app to restore focus
        previousApp.activate(options: [.activateIgnoringOtherApps])
        // Restoring focus - no logging needed
    }
    
    
    func getPreviousAppPid() -> pid_t? {
        // Return the saved frontmost app PID (for focus verification)
        return previousFrontmostApp?.processIdentifier
    }
    
    func isWindowVisible() -> Bool {
        return window?.isVisible ?? false
    }
    
    var isWindowKey: Bool {
        return window?.isKeyWindow ?? false
    }

    // MARK: - Present helpers (must stay in-file to access privates)
    @MainActor
    private func present(with viewModel: ClipboardHistoryViewModel) {
        // Reuse existing window if possible
        if let window = self.window {
            let target = self.targetScreen()
            let expected = self.centeredFrame(for: window.frame.size, on: target)
            let needsMove = window.screen != target || window.frame.origin != expected.origin
            
            if needsMove {
                window.orderOut(nil)
                window.setFrame(expected, display: false, animate: false)
            }

            // Frame reuse - no logging needed
            
            window.alphaValue = 1.0
            applyWindowPresentation(for: window)
            // Don't make window key - this prevents it from stealing focus
            // Keyboard events are handled by overriding keyDown/keyUp in NonFocusStealingPanel
            window.orderFrontRegardless()
            updateClickMonitor()
            setupEscMonitor()  // Setup ESC key monitor
            return
        }

        let contentSize = NSSize(width: 360, height: 480)
        let content = MenuBarContentView(viewModel: viewModel, historyOnly: true, applySwiftUIBackground: true)
            .frame(width: contentSize.width, height: contentSize.height)

        let hosting = NSHostingController(rootView: content)

        let style: NSWindow.StyleMask = [.titled, .fullSizeContentView, .utilityWindow]

        // Compute centered content rect up front so the panel is born at its final position on the correct screen.
        let target = self.targetScreen()
        let desiredFrame = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize), styleMask: style)
        let centeredFrame = self.centeredFrame(for: desiredFrame.size, on: target)

        // Start with a neutral rect, then apply the final frame (avoids zero-size logs).
        // Use NonFocusStealingPanel to prevent window from stealing focus
        let panel = NonFocusStealingPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: style,
            backing: .buffered,
            defer: false
        )

        panel.title = "Hypo History"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        
        applyWindowPresentation(for: panel)
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        hosting.view.wantsLayer = false

        // Apply the final centered frame using known frame size (no reliance on pre-layout zero sizes).
        panel.setFrame(centeredFrame, display: false, animate: false)

        // Ensure layout has run; then log the actual size/frame after layout.
        panel.layoutIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()

        // Window can accept mouse events but won't steal keyboard focus
        panel.acceptsMouseMovedEvents = true

        self.window = panel

        panel.alphaValue = 1.0
        applyWindowPresentation(for: panel)
        // Don't make window key - just show it without stealing focus
        panel.orderFrontRegardless()
        updateClickMonitor()
        setupEscMonitor()  // Setup ESC key monitor
        
        // Focus search field after a short delay to allow window to appear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.focusSearchField()
        }
    }

    private func applyWindowPresentation(for panel: NSPanel) {
        // Level controls z-order; hidesOnDeactivate controls click-outside dismissal.
        let level = isPinned
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            : .floating
        panel.level = level
        panel.hidesOnDeactivate = !isPinned
    }

    private func updateClickMonitor() {
        removeClickMonitor()
        guard !isPinned, window != nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let window = self.window else { return }
            let clickPoint = NSEvent.mouseLocation
            if !window.frame.contains(clickPoint) {
                self.hide()
            }
        }
    }

    private func setupEscMonitor() {
        removeEscMonitor()
        guard !isPinned, window != nil, window?.isVisible == true else { return }
        
        // Use NSEvent local monitor to handle ESC key
        // This only intercepts events destined for our app, more native than Carbon hotkey
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // ESC key (keyCode 53)
            if event.keyCode == 53 {
                self.hide()
                return nil  // Consume the event
            }
            return event  // Pass through other keys
        }
    }
    
    private func removeEscMonitor() {
        if let monitor = escKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escKeyMonitor = nil
        }
    }
    
    nonisolated(unsafe) private static var eventHandlerInstalled = false
    
    private func removeClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
    
    private func focusSearchField() {
        guard let window = window, window.isVisible else { return }
        
        // Find the TextField in the view hierarchy
        guard let contentView = window.contentView else { return }
        
        // Search for NSTextField in the view hierarchy
        if let textField = findTextField(in: contentView) {
            window.makeFirstResponder(textField)
            logger.debug("✅ Search field focused")
        } else {
            logger.debug("⚠️ Search field not found")
        }
    }
    
    private func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }
        for subview in view.subviews {
            if let textField = findTextField(in: subview) {
                return textField
            }
        }
        return nil
    }

    private func center(_ window: NSWindow) {
        let screen = targetScreen(for: window)
        let visible = screen.visibleFrame
        let windowSize = window.frame.size
        let centerX = visible.midX - windowSize.width / 2
        let centerY = visible.midY - windowSize.height / 2

        // Move before showing to avoid on-screen jump; no animation.
        window.setFrame(NSRect(x: centerX, y: centerY, width: windowSize.width, height: windowSize.height), display: false, animate: false)
    }

    private func targetScreen(for window: NSWindow) -> NSScreen {
        // Prefer screen under mouse to avoid using a stale main screen when the menu bar lives elsewhere.
        let mouse = NSEvent.mouseLocation
        if let match = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return match
        }
        // Fall back to the screen the window is on, then main, then first available.
        return window.screen ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    private func targetScreen() -> NSScreen {
        // Convenience for when we create the window (no window yet)
        let mouse = NSEvent.mouseLocation
        if let match = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    private func centeredFrame(for size: NSSize, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
#endif
