#if canImport(AppKit)
import AppKit
import SwiftUI
import os.log

/// Presents the history view in a floating, centered window when the global hotkey fires.
final class HistoryPopupPresenter {
    static let shared = HistoryPopupPresenter()
    private let logger = HypoLogger(category: "HistoryPopupPresenter")
    private init() {}

    private var window: NSPanel?
    private var previousActiveApp: NSRunningApplication?
    private var isPinned: Bool = false  // Start unpinned - window can be dismissed by clicking outside
    private var globalClickMonitor: Any?

    func show(with viewModel: ClipboardHistoryViewModel) {
        logger.debug("📢 [HistoryPopupPresenter] show() called")
        previousActiveApp = NSWorkspace.shared.frontmostApplication
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
            
            // Restore focus immediately (before hiding) to ensure it's ready for paste
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
                self.logger.warning("⚠️ Window not visible, restoring focus anyway")
                self.restorePreviousFocus()
                completion()
                return
            }
            
            self.logger.debug("🔄 hideAndRestoreFocus called")
            
            // Restore focus immediately (before hiding) to ensure it's ready for paste
            self.restorePreviousFocus()
            
            // Hide window immediately (no animation) for faster paste
            window.orderOut(nil)
            window.alphaValue = 1.0  // Reset for next show
            self.removeClickMonitor()
            
            self.logger.debug("🔄 Window hidden, waiting for focus restore...")
            
            // Wait longer for focus to fully restore, then call completion
            // macOS needs time to actually switch focus between applications
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.logger.debug("✅ Focus restore delay complete, calling completion")
                completion()
            }
        }
    }
    
    func restorePreviousFocus() {
        // Restore focus to the application that was active before we showed the popup
        if let previousApp = previousActiveApp, previousApp != NSRunningApplication.current {
            previousApp.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            self.logger.debug("🔄 [HistoryPopupPresenter] Restored focus to: \(previousApp.localizedName ?? "unknown") (PID: \(previousApp.processIdentifier))")
        } else {
            // Fallback: try to find the frontmost application that's not us
            let runningApps = NSWorkspace.shared.runningApplications.filter { app in
                app.activationPolicy == .regular && app != NSRunningApplication.current
            }
            if let frontmost = runningApps.first {
                frontmost.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                self.logger.debug("🔄 [HistoryPopupPresenter] Fallback: Restored focus to: \(frontmost.localizedName ?? "unknown") (PID: \(frontmost.processIdentifier))")
            } else {
                self.logger.warning("⚠️ [HistoryPopupPresenter] No previous app found, cannot restore focus")
            }
        }
    }
    
    func getPreviousAppPid() -> pid_t? {
        if let previousApp = previousActiveApp, previousApp != NSRunningApplication.current {
            return previousApp.processIdentifier
        }
        // Fallback: find frontmost app
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && app != NSRunningApplication.current
        }
        return runningApps.first?.processIdentifier
    }

    // MARK: - Present helpers (must stay in-file to access privates)
    @MainActor
    private func present(with viewModel: ClipboardHistoryViewModel) {
        // Reuse existing window if possible
        if let window = self.window {
            self.logger.debug("🪟 [HistoryPopupPresenter] Reusing existing window")
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
            self.appendDebug("[HistoryPopupPresenter] reuse frame=\(frameStr) expected=\(expectedStr) screen=\(target.localizedName) moved=\(needsMove)\n")
            
            window.alphaValue = 1.0
            applyWindowPresentation(for: window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            updateClickMonitor()
            return
        }

        self.logger.debug("🆕 [HistoryPopupPresenter] Creating new window")

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
        let panel = NSPanel(
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

        let finalSize = panel.frame.size
        let postLayoutScreen = self.targetScreen(for: panel)
        let visiblePost = postLayoutScreen.visibleFrame
        let finalFrame = panel.frame

        let visibleStr = NSStringFromRect(visiblePost)
        let sizeStr = NSStringFromSize(finalSize)
        let frameStr = NSStringFromRect(finalFrame)
        // Window creation details removed for cleaner logs
        // self.logger.debug("📍 New window target screen: \(postLayoutScreen.localizedName), visible=\(visibleStr), finalSize=\(sizeStr), setFrame=\(frameStr)")
        // self.appendDebug("[HistoryPopupPresenter] new window screen=\(postLayoutScreen.localizedName) visible=\(visibleStr) size=\(sizeStr) frame=\(frameStr)\n")
        // Make window accept keyboard events
        panel.acceptsMouseMovedEvents = true
        panel.makeFirstResponder(hosting.view)

        self.window = panel

        self.logger.debug("🪟 [HistoryPopupPresenter] Displaying window at center")

        panel.alphaValue = 1.0
        NSApp.activate(ignoringOtherApps: true)
        applyWindowPresentation(for: panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        updateClickMonitor()

        self.logger.debug("✅ [HistoryPopupPresenter] Window displayed")
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
