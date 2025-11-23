#if canImport(AppKit)
import AppKit
import SwiftUI

/// Presents the history view in a floating, centered window when the global hotkey fires.
final class HistoryPopupPresenter {
    static let shared = HistoryPopupPresenter()
    private init() {}

    private var window: NSPanel?

    func show(with viewModel: ClipboardHistoryViewModel) {
        DispatchQueue.main.async {
            // Ensure view model has loaded data before showing popup
            Task { @MainActor in
                await viewModel.start()
            }
            
            if let window = self.window {
                // Center before showing to avoid visible movement
                self.center(window)

                // Fade in animation if window is already visible
                if window.isVisible {
                    window.alphaValue = 0.0
                }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                
                // Animate fade in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.allowsImplicitAnimation = true
                    window.animator().alphaValue = 1.0
                }
                return
            }

            let content = MenuBarContentView(viewModel: viewModel)
                .frame(width: 360, height: 480)

            let hosting = NSHostingController(rootView: content)

            // Calculate center position first
            let centerRect: NSRect
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                centerRect = NSRect(
                    x: visible.midX - 180,  // 360 / 2
                    y: visible.midY - 240,  // 480 / 2
                    width: 360,
                    height: 480
                )
            } else {
                // Fallback to screen center if main screen not available
                centerRect = NSRect(x: 0, y: 0, width: 360, height: 480)
            }

            let panel = NSPanel(
                contentRect: centerRect,
                styleMask: [.titled, .fullSizeContentView, .utilityWindow],
                backing: .buffered,
                defer: false
            )

            panel.title = "Hypo History"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentViewController = hosting

            self.window = panel
            // Window is already created at center position, no need to call center() again
            // which would cause visible movement

            // Fade in animation
            panel.alphaValue = 0.0
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            
            // Animate fade in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1.0
            }
        }
    }

    func hide() {
        DispatchQueue.main.async {
            guard let window = self.window, window.isVisible else { return }
            
            // Animate fade out
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                window.animator().alphaValue = 0.0
            }, completionHandler: {
                window.orderOut(nil)
                window.alphaValue = 1.0  // Reset for next show
            })
        }
    }

    private func center(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }

        let visible = screen.visibleFrame
        var frame = window.frame
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2

        // Move before showing to avoid on-screen jump; no animation.
        window.setFrame(frame, display: false, animate: false)
    }
}
#endif
