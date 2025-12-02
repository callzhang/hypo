#if canImport(AppKit)
import AppKit
import SwiftUI
import os.log

/// Custom NSPanel that doesn't steal focus from other applications
private class NonFocusStealingPanel: NSPanel {
    override var canBecomeKey: Bool {
        return false  // Window cannot become key window, won't steal focus
    }
    
    override var canBecomeMain: Bool {
        return false  // Window cannot become main window
    }
    
    // Override keyDown to handle ESC key and ignore other keyboard events
    // This prevents system alert sounds when keys are pressed while window is visible
    override func keyDown(with event: NSEvent) {
        // Handle ESC key (keyCode 53) to close window, regardless of pin status
        if event.keyCode == 53 {
            HistoryPopupPresenter.shared.hide()
            return
        }
        // Silently ignore all other keyboard events - don't call super
        // This prevents the system alert sound
    }
    
    // Also ignore keyUp events
    override func keyUp(with event: NSEvent) {
        // Silently ignore all keyboard events - don't call super
    }
    
    // Ignore flagsChanged events (modifier keys)
    override func flagsChanged(with event: NSEvent) {
        // Silently ignore modifier key changes - don't call super
    }
}

/// Presents the history view in a floating, centered window when the global hotkey fires.
final class HistoryPopupPresenter {
    static let shared = HistoryPopupPresenter()
    private let logger = HypoLogger(category: "HistoryPopupPresenter")
    private init() {}

    private var window: NSPanel?
    private var isPinned: Bool = false  // Start unpinned - window can be dismissed by clicking outside
    private var globalClickMonitor: Any?
    private var previousFrontmostApp: NSRunningApplication?  // Save the app that was frontmost before showing window

    func show(with viewModel: ClipboardHistoryViewModel) {
        // Save the frontmost app before showing window (for focus restoration)
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        logger.debug("💾 Saved frontmost app: \(previousFrontmostApp?.localizedName ?? "unknown")")
        
        DispatchQueue.main.async {
            Task { @MainActor in
                await viewModel.start()
                self.present(with: viewModel)
            }
        }
    }

    func hide() {
        DispatchQueue.main.async {
            guard let window = self.window, window.isVisible else { return }
            
            // Restore focus to previous app when hiding (works for ESC key and click-outside)
            self.restorePreviousFocus()
            
            // Animate fade out
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                window.animator().alphaValue = 0.0
            }, completionHandler: {
                window.orderOut(nil)
                window.alphaValue = 1.0  // Reset for next show
                self.removeClickMonitor()
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
            
            self.logger.debug("🔄 hideAndRestoreFocus called")
            
            // Hide window immediately (no animation) for faster paste
            window.orderOut(nil)
            window.alphaValue = 1.0  // Reset for next show
            self.removeClickMonitor()
            
            // CRITICAL: Restore focus to the previous frontmost app before pasting
            // This ensures the paste goes to the correct window
            self.restorePreviousFocus()
            
            // CRITICAL: Even though window doesn't steal focus, a visible window can still intercept
            // keyboard events. We must ensure the window is fully hidden before sending events.
            // Use a small delay to ensure window system has processed the orderOut and focus restoration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Verify window is actually hidden before proceeding
                if window.isVisible {
                    self.logger.warning("⚠️ Window still visible after orderOut, forcing hide")
                    window.orderOut(nil)
                }
                
                // Verify focus was restored
                let currentFrontmost = NSWorkspace.shared.frontmostApplication
                let expectedApp = self.previousFrontmostApp
                if let expected = expectedApp, let current = currentFrontmost {
                    if current.processIdentifier == expected.processIdentifier {
                        self.logger.debug("✅ Focus restored to: \(current.localizedName ?? "unknown")")
                    } else {
                        self.logger.warning("⚠️ Focus may not be restored correctly. Expected: \(expected.localizedName ?? "unknown"), Current: \(current.localizedName ?? "unknown")")
                    }
                }
                
                self.logger.debug("✅ Window hidden, calling completion")
                completion()
            }
        }
    }
    
    private func restorePreviousFocus() {
        guard let previousApp = previousFrontmostApp else {
            logger.debug("ℹ️ No previous app to restore focus to")
            return
        }
        
        // Activate the previous app to restore focus
        previousApp.activate(options: [.activateIgnoringOtherApps])
        logger.debug("🔄 Restoring focus to: \(previousApp.localizedName ?? "unknown")")
    }
    
    
    func getPreviousAppPid() -> pid_t? {
        // Return current frontmost app since focus never changed
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    
    func isWindowVisible() -> Bool {
        return window?.isVisible ?? false
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

            let frameStr = NSStringFromRect(window.frame)
            let expectedStr = NSStringFromRect(expected)
            self.logger.debug("📍 Reuse frame: \(frameStr) expected: \(expectedStr) screen: \(target.localizedName) moved=\(needsMove)")
            
            window.alphaValue = 1.0
            applyWindowPresentation(for: window)
            // Don't make window key - this prevents it from stealing focus
            // Keyboard events are handled by overriding keyDown/keyUp in NonFocusStealingPanel
            window.orderFrontRegardless()
            updateClickMonitor()
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

    private func removeClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
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

    private func appendDebug(_ text: String) {
        let url = URL(fileURLWithPath: "/tmp/hypo_debug.log")
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            _ = try? data.write(to: url)
        }
    }
}
#endif
