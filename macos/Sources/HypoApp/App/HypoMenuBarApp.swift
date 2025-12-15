#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
import Carbon
import ApplicationServices
#endif
#endif

#if canImport(AppKit)
// Check if accessibility permissions are granted (required for CGEvent to work)
private func checkAccessibilityPermissions(prompt: Bool = false) -> Bool {
    // Default to non‑prompting to avoid triggering the system permission dialog
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
}
#endif

// AppDelegate to ensure hotkey setup runs at app launch (not waiting for UI)
@MainActor
class HypoAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = HypoLogger(category: "HypoAppDelegate")
    private var hotKeyRef: EventHotKeyRef?
    private var altNumberHotKeys: [Int: EventHotKeyRef] = [:]
    private static var eventHandlerInstalled = false
    private var clipboardMonitor: ClipboardMonitor?
    
    override init() {
        super.init()
        // Removed logging to reduce duplicates
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.debug("🚀 [HypoAppDelegate] applicationDidFinishLaunching called")
        
        // CRITICAL: Activate the app to ensure menu bar icon appears
        // Menu bar apps need to activate to show their status item
        // Activate immediately and also with delays to catch different timing scenarios
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        
        // Setup Hotkey using Carbon API (more reliable than CGEventTap)
        // Note: Carbon RegisterEventHotKey does NOT require Accessibility permissions
        setupCarbonHotkey()
        
        // Start clipboard monitoring immediately so local copies are captured even before UI appears
        startClipboardMonitorIfNeeded()
        
        // Setup sleep/wake detection for LAN connection optimization
        setupSleepWakeDetection()
    }
    
    private func setupSleepWakeDetection() {
        #if canImport(AppKit)
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        // Listen for sleep notification
        notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSleep()
            }
        }
        
        // Listen for wake notification
        notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
        
        logger.info("✅ [HypoAppDelegate] Sleep/wake detection registered")
        #endif
    }
    
    private func handleSleep() {
        logger.info("😴 [HypoAppDelegate] System going to sleep - closing LAN connections")
        Task { @MainActor in
            // Access TransportManager through AppContext
            if let viewModel = AppContext.shared.historyViewModel,
               let transportManager = viewModel.transportManager {
                await transportManager.closeAllLanConnections()
            }
        }
    }
    
    private func handleWake() {
        logger.info("🌅 [HypoAppDelegate] System woke up - reconnecting LAN connections")
        Task { @MainActor in
            // Access TransportManager through AppContext
            if let viewModel = AppContext.shared.historyViewModel,
               let transportManager = viewModel.transportManager {
                await transportManager.reconnectAllLanConnections()
            }
        }
    }
    
    func setupCarbonHotkey() {
        logger.debug("🔧 setupCarbonHotkey() called")
        
        // Install event handler once (static check)
        if !Self.eventHandlerInstalled {
            logger.debug("🔧 [HypoAppDelegate] Installing Carbon event handler...")
            
            var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
            
            // Carbon event handler callback
            let handlerProc: EventHandlerProcPtr = { (nextHandler, theEvent, userData) -> OSStatus in
                // Log ALL hotkey events to see if we're receiving any
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    theEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                
                // Note: Can't use logger here as it's a C callback, use NSLog instead
                // Only log errors or unexpected conditions to reduce noise
                if err != noErr {
                    NSLog("⚠️ [HypoAppDelegate] Hotkey event error: err=\(err), id=\(hotKeyID.id)")
                    return err
                }
                
                if err == noErr {
                    if hotKeyID.id == 1 {
                        // Alt+V - Show history popup
                        // Note: Can't use logger here as this is a C callback, use NSLog
                        NSLog("🎯 [HypoAppDelegate] HOTKEY TRIGGERED: Alt+V pressed")
                        
                        DispatchQueue.main.async {
                            // CRITICAL: Save frontmost app BEFORE activating Hypo
                            // This ensures we capture the actual previous app, not Hypo itself
                            HistoryPopupPresenter.shared.saveFrontmostAppBeforeActivation()
                            
                            NSApp.activate(ignoringOtherApps: true)
                            
                            if let viewModel = AppContext.shared.historyViewModel {
                                HistoryPopupPresenter.shared.show(with: viewModel)
                            }
                        }
                    } else if hotKeyID.id == 999 {
                        // ESC key - Close history popup
                        NSLog("🎯 [HypoAppDelegate] HOTKEY TRIGGERED: ESC pressed")
                        DispatchQueue.main.async {
                            HistoryPopupPresenter.shared.hide()
                        }
                    } else if hotKeyID.id >= 10 && hotKeyID.id <= 18 {
                        // Alt+1 through Alt+9 (id 10-18)
                        let num = Int(hotKeyID.id - 9)  // 10->1, 11->2, ..., 18->9
                        // Note: Can't use logger here as this is a C callback, use NSLog
                        NSLog("🎯 [HypoAppDelegate] HOTKEY TRIGGERED: Alt+\(num) pressed")
                        
                        DispatchQueue.main.async {
                            if let viewModel = AppContext.shared.historyViewModel {
                                // Get filtered items
                                let filteredItems = viewModel.items
                                
                                // Alt+1 maps to item 2 (index 1), Alt+2 maps to item 3 (index 2), etc.
                                let itemIndex = num  // num is 1-9, maps to array index 1-9 (items 2-10)
                                if itemIndex < filteredItems.count {
                                    let item = filteredItems[itemIndex]
                                    
                                    // Note: Can't use logger here as this is called from C callback context
                                    // Minimize logging - only log if needed for debugging
                                    
                                    // Highlight the item before copying (post notification for view to update)
                                    NotificationCenter.default.post(
                                        name: NSNotification.Name("HighlightHistoryItem"),
                                        object: nil,
                                        userInfo: ["itemId": item.id]
                                    )
                                    
                                    // Copy to clipboard first (for all content types)
                                    // This ensures clipboard is ready before focus restore
                                    viewModel.copyToPasteboard(item)
                                    
                                    // Hide popup and restore focus immediately (clipboard copy is synchronous)
                                    HistoryPopupPresenter.shared.hideAndRestoreFocus {
                                        // Use Cmd+V for all content types (most reliable method)
                                        pasteToCursorAtCurrentPosition(entry: item)
                                    }
                                    
                                    // Clear highlight after brief delay
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        NotificationCenter.default.post(
                                            name: NSNotification.Name("ClearHighlightHistoryItem"),
                                            object: nil
                                        )
                                    }
                                } else {
                                    // Note: Can't use logger here as this is a C callback
                                    NSLog("⚠️ [HypoAppDelegate] Item index \(itemIndex) out of range (count: \(filteredItems.count))")
                                }
                            }
                        }
                    }
                } else if err != noErr {
                    NSLog("⚠️ [HypoAppDelegate] GetEventParameter failed: \(err)")
                }
                return noErr
            }
            
            var eventHandler: EventHandlerRef?
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                handlerProc,
                1,
                &eventSpec,
                nil,
                &eventHandler
            )
            
        if installStatus == noErr {
            Self.eventHandlerInstalled = true
            logger.debug("✅ [HypoAppDelegate] Event handler installed successfully")
        } else {
            logger.error("❌ [HypoAppDelegate] Failed to install Carbon event handler: \(installStatus)")
            return
        }
        }
        
        // Check if hotkey is already registered
        if self.hotKeyRef != nil {
            logger.debug("ℹ️ [HypoAppDelegate] Hotkey already registered, skipping")
            return
        }
        
        // Register hotkey: Alt+V (keyCode 9 = 'V')
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4859504F) // "HYPO" signature
        hotKeyID.id = 1
        
        var hotKeyRef: EventHotKeyRef?
        let keyCode = UInt32(9) // 'V' key
        let modifiers = UInt32(optionKey) // Alt/Option
        
        logger.debug("🔧 [HypoAppDelegate] Registering hotkey: keyCode=\(keyCode), modifiers=\(modifiers), signature=\(hotKeyID.signature), id=\(hotKeyID.id)")
        
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status == noErr, let hotKey = hotKeyRef {
            self.hotKeyRef = hotKey
            logger.debug("✅ [HypoAppDelegate] Carbon hotkey registered: Alt+V (status: \(status), ref: \(hotKey))")
        } else if self.hotKeyRef == nil {
            // If registration failed but we don't have a ref, check if it's just because hotkey already exists
            if status == -9878 { // eventHotKeyExistsErr
                logger.debug("🔄 [HypoAppDelegate] Hotkey already exists (status=-9878), skipping registration")
                // Note: We can't unregister without the ref, so we'll just log this
            } else {
                // Only log warning for actual errors (not "already exists")
                logger.warning("⚠️ [HypoAppDelegate] Hotkey registration returned status=\(status). Ref: \(hotKeyRef != nil ? "exists" : "nil")")
            }
        }
        
        // Register Alt+1 through Alt+9 hotkeys
        registerAltNumberHotkeys()
    }
    
    private func registerAltNumberHotkeys() {
        // Key codes: 18=1, 19=2, 20=3, 21=4, 23=5, 22=6, 26=7, 28=8, 25=9
        let numberKeyCodes: [Int: UInt32] = [
            1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
            6: 22, 7: 26, 8: 28, 9: 25
        ]
        
        for (num, keyCode) in numberKeyCodes {
            var hotKeyID = EventHotKeyID()
            hotKeyID.signature = OSType(0x4859504F) // "HYPO" signature
            hotKeyID.id = UInt32(9 + num) // IDs 10-18 for Alt+1 through Alt+9
            
            var hotKeyRef: EventHotKeyRef?
            let modifiers = UInt32(optionKey) // Alt/Option
            
            let status = RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            
            if status == noErr, let hotKey = hotKeyRef {
                altNumberHotKeys[num] = hotKey
                logger.debug("✅ [HypoAppDelegate] Carbon hotkey registered: Alt+\(num) (status: \(status))")
            } else {
                // Log as debug if hotkey already exists (expected behavior), warning for actual errors
                if status == -9878 { // eventHotKeyExistsErr
                    logger.debug("🔄 [HypoAppDelegate] Alt+\(num) already registered (status=-9878), skipping")
                } else {
                    logger.warning("⚠️ [HypoAppDelegate] Failed to register Alt+\(num): status=\(status)")
                }
            }
        }
    }
    
    /// Start clipboard monitoring as early as possible so local copies are captured even before the UI appears.
    @MainActor
    private func startClipboardMonitorIfNeeded() {
        // Reuse shared monitor if one already exists
        if let existing = AppContext.shared.clipboardMonitor {
            clipboardMonitor = existing
            logger.debug("📋 [HypoAppDelegate] ClipboardMonitor already running, reusing shared instance")
            return
        }
        
        guard let viewModel = AppContext.shared.historyViewModel else {
            logger.warning("⚠️ [HypoAppDelegate] Cannot start ClipboardMonitor: historyViewModel not set yet")
            return
        }
        
        guard let uuid = UUID(uuidString: viewModel.localDeviceId) else {
            logger.error("❌ [HypoAppDelegate] Failed to parse localDeviceId: \(viewModel.localDeviceId)")
            return
        }
        
        let identity = DeviceIdentity()
        let monitor = ClipboardMonitor(
            deviceId: uuid,
            platform: identity.platform,
            deviceName: identity.deviceName
        )
        monitor.delegate = viewModel
        monitor.start()
        
        AppContext.shared.clipboardMonitor = monitor
        clipboardMonitor = monitor
        logger.debug("📋 [HypoAppDelegate] ClipboardMonitor started at launch (delegate set: \(monitor.delegate != nil))")
    }
    
    private func pasteToCursor() {
        // Simulate Cmd+V to paste at cursor position
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true) else { return }
            keyDownEvent.flags = .maskCommand
            keyDownEvent.post(tap: .cghidEventTap)
            
            guard let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else { return }
            keyUpEvent.flags = .maskCommand
            keyUpEvent.post(tap: .cghidEventTap)
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up hotkeys
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
        }
        for (_, hotKey) in altNumberHotKeys {
            UnregisterEventHotKey(hotKey)
        }
        altNumberHotKeys.removeAll()
    }
}

// Global reference to prevent AppDelegate deallocation
private var globalAppDelegate: HypoAppDelegate?

/// Directly type text at cursor position (similar to pynput) - more reliable than Cmd+V
/// This method directly inputs text characters without relying on clipboard
/// Uses CGEvent to inject text character by character for maximum reliability
private func typeTextAtCursor(_ text: String) {
    let logger = HypoLogger(category: "typeTextAtCursor")
    
    // Longer delay to ensure focus is fully restored and window is ready
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        logger.debug("⌨️ Typing text directly at cursor (\(text.count) chars)")
        
        // Verify focus is restored
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isHypoApp = frontmostApp?.bundleIdentifier?.contains("hypo") ?? false
        if isHypoApp {
            logger.warning("⚠️ Hypo app is still frontmost, focus may not be restored")
        } else {
            logger.debug("✅ Focus restored to: \(frontmostApp?.localizedName ?? "unknown")")
        }
        
        // Create keyboard event source
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            logger.error("❌ Failed to create event source")
            return
        }
        
            // Type character by character for maximum reliability (similar to pynput)
            // This ensures each character is properly input even if some fail
            for (index, char) in text.enumerated() {
                // Convert character to UTF-16 code units (UniChar is UInt16)
                let utf16Chars = Array(char.utf16)
                
                // Create key down event with Unicode character
                guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
                    logger.error("❌ Failed to create keyDown event for char at index \(index)")
                    continue
                }
                
                // Set Unicode string (single character as UTF-16)
                var utf16Value = utf16Chars[0]
                keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: &utf16Value)
                
                // Post key down
                keyDownEvent.post(tap: .cghidEventTap)
                
                // Small delay between characters for reliability (5ms)
                if index < text.count - 1 {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                
                // Create and post key up event
                if let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    var utf16ValueUp = utf16Value
                    keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: &utf16ValueUp)
                    keyUpEvent.post(tap: .cghidEventTap)
                }
            }
        
        logger.debug("✅ Text typed successfully (\(text.count) chars)")
    }
}

// Standalone function to paste at cursor (can be called from C callbacks)
// Uses Cmd+V for all content types (most reliable method on macOS)
// CRITICAL: Window must be fully hidden before sending keyboard events
// Even with canBecomeKey=false, a visible window can intercept events
private func pasteToCursorAtCurrentPosition(entry: ClipboardEntry? = nil) {
    let logger = HypoLogger(category: "pasteToCursor")
    
    // Check accessibility permissions (required for CGEvent to work).
    // Do NOT prompt the user; if unavailable, fall back to “copy only” and let the user press Cmd+V.
    if !checkAccessibilityPermissions(prompt: true) {
        logger.notice("⚠️ Accessibility permission missing – copied item is ready, ask user to press Cmd+V")
        return
    }
    
    // CRITICAL: Window must be fully hidden and focus restored before sending keyboard events
    // hideAndRestoreFocus already waits 0.05s and verifies window is hidden
    // Add minimal delay (0.05s) to ensure focus restoration is complete
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        // Verify window is not visible before sending events (quick check)
        let windowVisible = HistoryPopupPresenter.shared.isWindowVisible()
        if windowVisible {
            logger.warning("⚠️ Window still visible, adding small delay")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                performPasteAction()
            }
        } else {
            // Verify focus is on the correct app before pasting (non-blocking)
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            let expectedApp = HistoryPopupPresenter.shared.getPreviousAppPid()
            if let expected = expectedApp, let current = frontmostApp {
                if current.processIdentifier == expected {
                    logger.debug("✅ Focus verified on: \(current.localizedName ?? "unknown")")
                } else {
                    logger.debug("⚠️ Focus not on expected app. Expected PID: \(expected), Current: \(current.processIdentifier) (\(current.localizedName ?? "unknown"))")
                }
            }
            // Proceed with paste immediately (don't block on focus verification)
            performPasteAction()
        }
    }
}

private func performPasteAction() {
    let logger = HypoLogger(category: "pasteToCursor")
    logger.debug("📋 Attempting to paste via Cmd+V...")
    
    // Method 1: Try using cgSessionEventTap first (more reliable for user session events)
    // This posts events to the current user's session, which is more reliable than cghidEventTap
    let success = performPasteWithSessionTap()
    
    if !success {
        // Fallback: Try cghidEventTap if session tap fails
        logger.debug("⚠️ Session tap failed, trying HID tap...")
        performPasteWithHIDTap()
    }
}

private func performPasteWithSessionTap() -> Bool {
    let logger = HypoLogger(category: "pasteToCursor")
    
    // Create event source with user activity state (more reliable for paste)
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        logger.error("❌ Failed to create event source")
        return false
    }
    
    // Create key down event for 'V' (virtual key 0x09) with Cmd modifier
    guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
        logger.error("❌ Failed to create keyDown event")
        return false
    }
    keyDownEvent.flags = .maskCommand
    
    // Post to session event tap (sends to current user session, more reliable)
    keyDownEvent.post(tap: .cgSessionEventTap)
    logger.debug("📋 KeyDown posted via session tap (Cmd+V)")
    
    // Small delay between key down and key up
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        guard let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            logger.error("❌ Failed to create keyUp event")
            return
        }
        keyUpEvent.flags = .maskCommand
        keyUpEvent.post(tap: .cgSessionEventTap)
        logger.debug("✅ KeyUp posted via session tap")
    }
    
    return true
}

private func performPasteWithHIDTap() {
    let logger = HypoLogger(category: "pasteToCursor")
    
    // Create event source
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        logger.error("❌ Failed to create event source")
        return
    }
    
    // Create key down event for 'V' (virtual key 0x09) with Cmd modifier
    guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
        logger.error("❌ Failed to create keyDown event")
        return
    }
    keyDownEvent.flags = .maskCommand
    
    // Post to HID event tap (fallback method)
    keyDownEvent.post(tap: .cghidEventTap)
    logger.debug("📋 KeyDown posted via HID tap (Cmd+V)")
    
    // Small delay between key down and key up
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        guard let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            logger.error("❌ Failed to create keyUp event")
            return
        }
        keyUpEvent.flags = .maskCommand
        keyUpEvent.post(tap: .cghidEventTap)
        logger.debug("✅ KeyUp posted via HID tap")
    }
}

public struct HypoMenuBarApp: App {
    private let logger = HypoLogger(category: "HypoMenuBarApp")
    // Connect AppDelegate to ensure setup runs at launch
    @NSApplicationDelegateAdaptor(HypoAppDelegate.self) var appDelegate
    
    @StateObject private var viewModel: ClipboardHistoryViewModel
    @State private var monitor: ClipboardMonitor?
    @State private var globalShortcutMonitor: Any?
    @State private var eventTap: CFMachPort?
    @State private var runLoopSource: CFRunLoopSource?

    public init() {
        logger.info("🚀 [HypoMenuBarApp] Initializing app (viewModel setup)")
        
        // Create shared dependencies
        let historyStore = HistoryStore()
        let server = LanWebSocketServer()
        let provider = DefaultTransportProvider(server: server)
        
        // Create transport manager with history store for incoming clipboard handling
        let transportManager = TransportManager(
            provider: provider,
            webSocketServer: server,
            historyStore: historyStore
        )
        
        let viewModel = ClipboardHistoryViewModel(
            store: historyStore,
            transportManager: transportManager
        )
        
        transportManager.setHistoryViewModel(viewModel)
        
        _viewModel = StateObject(wrappedValue: viewModel)
        AppContext.shared.historyViewModel = viewModel

        // CRITICAL: Start loading data immediately so popup has data when hotkey is pressed
        Task { @MainActor in
            await viewModel.start()
        }

        // CRITICAL: Set up AppDelegate immediately since @NSApplicationDelegateAdaptor
        // doesn't work when App struct is in a library called from a different module
        // Store strong reference in global variable to prevent deallocation
        let delegate = HypoAppDelegate()
        globalAppDelegate = delegate  // Store in global to prevent deallocation
        
        // Set up delegate after NSApp is ready
        DispatchQueue.main.async {
            NSApplication.shared.delegate = delegate
            // Call applicationDidFinishLaunching manually
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        }
    }

    public var body: some Scene {
        MenuBarExtra(content: {
            MenuBarContentView(viewModel: viewModel, applySwiftUIBackground: false)
                .frame(width: 360, height: 480)
                .environmentObject(viewModel)
                .onAppear {
                    // CRITICAL FALLBACK: If @NSApplicationDelegateAdaptor didn't work, set up delegate manually
                    if NSApplication.shared.delegate == nil || !(NSApplication.shared.delegate is HypoAppDelegate) {
                        let delegate = HypoAppDelegate()
                        globalAppDelegate = delegate
                        NSApplication.shared.delegate = delegate
                        // Call applicationDidFinishLaunching manually
                        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
                    }
                    
                    // CRITICAL: Activate app when MenuBarExtra appears to ensure status item is visible
                    // This is needed when app is launched by double-clicking (not via open command)
                    // Activate immediately and also with delays to catch different timing scenarios
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                    
                    // CRITICAL: Ensure setHistoryViewModel is called when view appears
                    if let transportManager = viewModel.transportManager {
                        transportManager.setHistoryViewModel(viewModel)
                    }
                    
                    // Start clipboard monitor - this is the primary place it should start
                    setupMonitor()
                    // Global shortcut registration is handled by HypoAppDelegate (Carbon hotkey)
                }
                .onDisappear {
                    // Keep the global shortcut active across menu open/close cycles.
                }
                .task {
                    // Also call it from .task as backup
                    if let transportManager = viewModel.transportManager {
                        logger.debug("🚀 [HypoMenuBarApp] Ensuring viewModel is set")
                        transportManager.setHistoryViewModel(viewModel)
                    }
                    await viewModel.start()
                    // Ensure monitor is started in .task as well (runs even if .onAppear doesn't)
                    setupMonitor()
                    
                    // CRITICAL: Also activate here as backup to ensure menu bar icon appears
                    // This runs even if .onAppear doesn't fire
                    // Activate multiple times with delays to ensure it works
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s more (total 0.5s)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .onOpenURL { url in
                    Task { await viewModel.handleDeepLink(url) }
                }
                .background(MenuBarIconRightClickHandler(viewModel: viewModel))
        }, label: {
            menuBarIcon()
        })
        .menuBarExtraStyle(.window)
    }
    
    private func setupRightClickMenu() {
        // Set up right-click menu after MenuBarExtra creates the status item
        // Right-click handling disabled (status item uses default behavior)
    }
    
    private func setupMonitor() {
        // Reuse monitor if AppDelegate already started it
        if let existing = AppContext.shared.clipboardMonitor {
            monitor = existing
            logger.debug("📋 [HypoMenuBarApp] Reusing shared ClipboardMonitor (delegate set: \(existing.delegate != nil))")
            return
        }
        guard monitor == nil else { return }
        // Use the same device identity as the viewModel to ensure device IDs match
        let deviceId = viewModel.localDeviceId
        guard let uuid = UUID(uuidString: deviceId) else {
            logger.error("❌ [HypoMenuBarApp] Failed to parse deviceId as UUID: \(deviceId)")
            return
        }
        let deviceIdentity = DeviceIdentity()
        let monitor = ClipboardMonitor(
            deviceId: uuid,
            platform: deviceIdentity.platform,
            deviceName: deviceIdentity.deviceName
        )
        monitor.delegate = viewModel
        monitor.start()
        AppContext.shared.clipboardMonitor = monitor
        logger.debug("📋 [HypoMenuBarApp] ClipboardMonitor started, deviceId: \(deviceId), delegate set: \(monitor.delegate != nil)")
        self.monitor = monitor
    }
    
    private func setupGlobalShortcut() {
        // Using Shift+Cmd+V (V for View/History) to avoid system shortcut conflicts
        // Shift+Cmd+C conflicts with Terminal/Color Picker system shortcuts
        
        // Avoid duplicate setup
        if globalShortcutMonitor != nil {
            logger.debug("ℹ️ [HypoMenuBarApp] Global shortcut already set up, skipping")
            return
        }
        
        logger.debug("🔧 [HypoMenuBarApp] setupGlobalShortcut() called - Using Shift+Cmd+V")
        
        // Clean up existing monitors
        if let monitor = globalShortcutMonitor {
            NSEvent.removeMonitor(monitor)
            globalShortcutMonitor = nil
        }
        
        // Clean up CGEventTap if exists (from previous attempts)
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        
        // Use NSEvent monitors with Alt+V (doesn't conflict with system shortcuts)
        setupNSEventShortcut()
    }
    
    private func setupNSEventShortcut() {
        // Use NSEvent monitors with Shift+Cmd+V (V for View/History)
        // This avoids conflicts with system shortcuts like Shift+Cmd+C (Color Picker)
        
        logger.debug("🔧 [HypoMenuBarApp] Setting up NSEvent shortcut for Shift+Cmd+V")
        
        // Local monitor (works when app is active)
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let hasCmd = event.modifierFlags.contains(.command)
            let hasShift = event.modifierFlags.contains(.shift)
            
            // Debug log for all key events
            if hasCmd && hasShift {
                logger.debug("🔍 [NSEvent] Key pressed: '\(key)' (Cmd+Shift)")
            }
            
            if hasCmd && hasShift && key == "v" {
                logger.debug("🎯 [NSEvent] Intercepted Shift+Cmd+V - showing popup")
                
                // CRITICAL: Save frontmost app BEFORE activating Hypo
                HistoryPopupPresenter.shared.saveFrontmostAppBeforeActivation()
                
                // Activate app first, then show popup
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.showHistoryPopup()
                }
                return nil  // Consume the event
            }
            return event
        }
        globalShortcutMonitor = localMonitor
        
        logger.debug("✅ [HypoMenuBarApp] NSEvent shortcut registered (local only): Shift+Cmd+V")
    }
    
    private func showHistoryPopup() {
        logger.debug("📢 [HypoMenuBarApp] showHistoryPopup() called - posting notifications")
        
        // Post notification to show history popup
        // The MenuBarContentView will handle centering and showing the window
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowHistoryPopup"),
            object: nil
        )
        
        // Also ensure history section is selected
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowHistorySection"),
            object: nil
        )
        
        logger.debug("✅ [HypoMenuBarApp] Notifications posted: ShowHistoryPopup, ShowHistorySection")
    }
}

private enum MenuSection: String, CaseIterable, Identifiable {
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock"
        case .settings: return "gear"
        }
    }
}

extension HypoMenuBarApp {
    /// Helper to create a template image for menu bar
    private func makeTemplateImage(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        return image
    }
    
    /// Load the menu bar icon from the app bundle
    @ViewBuilder
    func menuBarIcon() -> some View {
        // Try to load from MenuBarIcon.iconset (monochrome template version)
        if let iconPath = Bundle.main.path(forResource: "MenuBarIcon", ofType: "iconset"),
           let iconImage = NSImage(contentsOfFile: "\(iconPath)/icon_16x16.png") {
            // Menu bar icon is already designed as template
            Image(nsImage: makeTemplateImage(iconImage))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            // Fallback: Use system clipboard icon
            // Log error if primary icon is missing (build/packaging issue)
            // Note: Logging happens in onAppear to avoid ViewBuilder issues
            Image(systemName: "clipboard")
                .onAppear {
                    #if canImport(os)
                    let iconLogger = HypoLogger(category: "HypoMenuBarApp")
                    iconLogger.error("❌ [HypoMenuBarApp] MenuBarIcon.iconset not found in bundle. This is a build/packaging issue.")
                    #endif
                }
        }
    }
}

struct MenuBarContentView: View {
    private let logger = HypoLogger(category: "MenuBarContentView")
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    var historyOnly: Bool = false
    var applySwiftUIBackground: Bool = true
    @State private var windowPinned = HistoryPopupPresenter.shared.pinned
    @State private var selectedSection: MenuSection = .history
    @State private var search = ""
    @State private var isVisible = false
    @State private var eventMonitor: Any?
    @State private var isHandlingPopup = false
    @State private var historySectionObserver: NSObjectProtocol?
    @State private var historyPopupObserver: NSObjectProtocol?
    @State private var settingsSectionObserver: NSObjectProtocol?
    @State private var highlightedItemId: UUID?
    @State private var currentColorScheme: ColorScheme? = nil

    var body: some View {
        VStack(spacing: 12) {
            if historyOnly {
                HStack {
                    Spacer()
                    Text("Hypo")
                        .font(.headline)
                    Spacer()
                    Button(action: toggleWindowPin) {
                        Image(systemName: windowPinned ? "pin.fill" : "pin")
                            .foregroundStyle(windowPinned ? .orange : .primary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help(windowPinned ? "Unpin window (allow other apps on top)" : "Pin window on top")
                }
                .padding(.top, 4)
            }
            
            if !historyOnly {
                Picker("Section", selection: $selectedSection) {
                    ForEach(MenuSection.allCases) { section in
                        Label(section.title, systemImage: section.icon).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Menu sections")
            }
            
            let section = historyOnly ? MenuSection.history : selectedSection
            switch section {
            case .history:
                HistorySectionView(
                    viewModel: viewModel,
                    search: $search,
                    highlightedItemId: $highlightedItemId
                )
            case .settings:
                SettingsSectionView(viewModel: viewModel)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(applySwiftUIBackground ? AnyView(Color.clear.background(.ultraThinMaterial)) : AnyView(Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(isVisible ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .preferredColorScheme(currentColorScheme)
        .onAppear {
            isVisible = true
            windowPinned = HistoryPopupPresenter.shared.pinned
            if historyOnly { selectedSection = .history }
            // Initialize color scheme from viewModel
            currentColorScheme = viewModel.appearancePreference.colorScheme
            // Trigger connection status probe when window appears to refresh peer status
            // Defer to avoid blocking paste operations - run after a short delay
            if let transportManager = viewModel.transportManager {
                Task {
                    // Delay probe to avoid blocking paste operations (0.5s delay)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await transportManager.probeConnectionStatus()
                }
            }
            // Setup keyboard shortcut monitor for Cmd+1 through Cmd+9
            setupKeyboardShortcuts()
        }
        // Set up observers as soon as view is created (not waiting for onAppear)
        // This ensures they're ready before Carbon hotkey can fire
        .task {
            setupHistorySectionListener()
            setupHighlightObserver()
            // Initialize color scheme from viewModel
            currentColorScheme = viewModel.appearancePreference.colorScheme
        }
        .onChange(of: viewModel.appearancePreference) { newPreference in
            // Update color scheme when preference changes
            currentColorScheme = newPreference.colorScheme
        }
        .onDisappear {
            isVisible = false
            // Remove keyboard shortcut monitor
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
            // Note: We keep notification observers active even when view disappears
            // so hotkey continues to work when menu is closed
        }
    }

    private func toggleWindowPin() {
        HistoryPopupPresenter.shared.togglePinned()
        windowPinned = HistoryPopupPresenter.shared.pinned
    }
    
    private func setupKeyboardShortcuts() {
        // Remove existing monitor if any
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        
        // NOTE: We don't set up keyboard monitors here because:
        // 1. The window has canBecomeKey=false, so it cannot receive keyboard events
        // 2. Setting up local/global monitors would cause system alert sounds
        // 3. Carbon hotkeys in HypoAppDelegate already handle Alt+1 through Alt+9 globally
        //    without requiring window focus, so these monitors are redundant
        
        self.logger.debug("ℹ️ [MenuBarContentView] Keyboard shortcuts handled by Carbon hotkeys (no local monitors needed)")
    }
    
    /// Directly type text at cursor position (similar to pynput) - more reliable than Cmd+V
    /// Uses CGEvent to inject text character by character for maximum reliability
    private func typeTextAtCursor(_ text: String) {
        // Longer delay to ensure focus is fully restored and window is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.logger.debug("⌨️ Typing text directly at cursor (\(text.count) chars)")
            
            // Verify focus is restored
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            let isHypoApp = frontmostApp?.bundleIdentifier?.contains("hypo") ?? false
            if isHypoApp {
                self.logger.warning("⚠️ Hypo app is still frontmost, focus may not be restored")
            } else {
                self.logger.debug("✅ Focus restored to: \(frontmostApp?.localizedName ?? "unknown")")
            }
            
            // Create keyboard event source
            guard let source = CGEventSource(stateID: .hidSystemState) else {
                self.logger.error("❌ Failed to create event source")
                return
            }
            
            // Type character by character for maximum reliability (similar to pynput)
            // This ensures each character is properly input even if some fail
            for (index, char) in text.enumerated() {
                // Convert character to UTF-16 code units (UniChar is UInt16)
                let utf16Chars = Array(char.utf16)
                
                // Create key down event with Unicode character
                guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
                    self.logger.error("❌ Failed to create keyDown event for char at index \(index)")
                    continue
                }
                
                // Set Unicode string (single character as UTF-16)
                var utf16Value = utf16Chars[0]
                keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: &utf16Value)
                
                // Post key down
                keyDownEvent.post(tap: .cghidEventTap)
                
                // Small delay between characters for reliability (5ms)
                if index < text.count - 1 {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                
                // Create and post key up event
                if let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    var utf16ValueUp = utf16Value
                    keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: &utf16ValueUp)
                    keyUpEvent.post(tap: .cghidEventTap)
                }
            }
            
            self.logger.debug("✅ Text typed successfully (\(text.count) chars)")
        }
    }
    
    private func pasteToCursor(entry: ClipboardEntry? = nil) {
        // Use Cmd+V for all content types (most reliable method on macOS)
        // CRITICAL: Window must be fully hidden before sending keyboard events
        
        // Check accessibility permissions (required for CGEvent to work)
        if !checkAccessibilityPermissions() {
            self.logger.error("❌ Accessibility permissions not granted - CGEvent will not work")
            self.logger.error("   Please grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
            return
        }
        
        // CRITICAL: Window must be fully hidden before sending keyboard events
        // The hideAndRestoreFocus already waits for window to be hidden, so we add a small delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Verify window is not visible before sending events
            let windowVisible = HistoryPopupPresenter.shared.isWindowVisible()
            if windowVisible {
                self.logger.warning("⚠️ Window still visible, delaying paste")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.performPasteActionForView()
                }
            } else {
                self.performPasteActionForView()
            }
        }
    }
    
    private func performPasteActionForView() {
        self.logger.debug("📋 Attempting to paste via Cmd+V...")
        
        // Method 1: Try using cgSessionEventTap first (more reliable for user session events)
        let success = self.performPasteWithSessionTapForView()
        
        if !success {
            // Fallback: Try cghidEventTap if session tap fails
            self.logger.debug("⚠️ Session tap failed, trying HID tap...")
            self.performPasteWithHIDTapForView()
        }
    }
    
    private func performPasteWithSessionTapForView() -> Bool {
        // Create event source with user activity state (more reliable for paste)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            self.logger.error("❌ Failed to create event source")
            return false
        }
        
        guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
            self.logger.error("❌ Failed to create keyDown event")
            return false
        }
        keyDownEvent.flags = .maskCommand
        
        // Post to session event tap (sends to current user session, more reliable)
        keyDownEvent.post(tap: .cgSessionEventTap)
        self.logger.debug("📋 KeyDown posted via session tap (Cmd+V)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
                self.logger.error("❌ Failed to create keyUp event")
                return
            }
            keyUpEvent.flags = .maskCommand
            keyUpEvent.post(tap: .cgSessionEventTap)
            self.logger.debug("✅ KeyUp posted via session tap")
        }
        
        return true
    }
    
    private func performPasteWithHIDTapForView() {
        // Create event source
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            self.logger.error("❌ Failed to create event source")
            return
        }
        
        guard let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else {
            self.logger.error("❌ Failed to create keyDown event")
            return
        }
        keyDownEvent.flags = .maskCommand
        keyDownEvent.post(tap: .cghidEventTap)
        self.logger.debug("📋 KeyDown posted via HID tap (Cmd+V)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
                self.logger.error("❌ Failed to create keyUp event")
                return
            }
            keyUpEvent.flags = .maskCommand
            keyUpEvent.post(tap: .cghidEventTap)
            self.logger.debug("✅ KeyUp posted via HID tap")
        }
    }
    
    private func setupHistorySectionListener() {
        // Remove existing observers to prevent duplicates
        if let observer = historySectionObserver {
            NotificationCenter.default.removeObserver(observer)
            historySectionObserver = nil
        }
        if let observer = historyPopupObserver {
            NotificationCenter.default.removeObserver(observer)
            historyPopupObserver = nil
        }
        
        logger.debug("🔧 [MenuBarContentView] Setting up notification observers")
        
        // Set up observer for history section switch
        historySectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowHistorySection"),
            object: nil,
            queue: .main
        ) { [self] _ in
            selectedSection = .history
        }
        
        // Set up observer for showing popup - prevent duplicate calls
        historyPopupObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowHistoryPopup"),
            object: nil,
            queue: .main
        ) { [self] _ in
            guard !isHandlingPopup else { return }
            
            isHandlingPopup = true
            // Reset flag after handling
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isHandlingPopup = false
            }
        }
        
        // Set up observer for settings section switch
        settingsSectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowSettingsSection"),
            object: nil,
            queue: .main
        ) { [self] _ in
            selectedSection = .settings
        }
        
        logger.debug("✅ [MenuBarContentView] Notification observers set up")
    }
    
    private func setupHighlightObserver() {
        // Set up observer for highlighting items when Alt+index is pressed
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HighlightHistoryItem"),
            object: nil,
            queue: .main
        ) { notification in
            if let itemId = notification.userInfo?["itemId"] as? UUID {
                self.logger.debug("✨ [MenuBarContentView] Highlighting item: \(itemId)")
                self.highlightedItemId = itemId
            }
        }
        
        // Set up observer for clearing highlight
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ClearHighlightHistoryItem"),
            object: nil,
            queue: .main
        ) { _ in
            self.highlightedItemId = nil
        }
    }
    
}


private struct LatestClipboardView: View {
    let entry: ClipboardEntry?
    @ObservedObject var viewModel: ClipboardHistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Latest", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if let entry {
                    Button {
                        viewModel.copyToPasteboard(entry)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy latest clipboard item")

                    Button {
                        viewModel.togglePin(entry)
                    } label: {
                        Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(entry.isPinned ? "Unpin latest item" : "Pin latest item")
                }
            }

            if let entry {
                ClipboardCard(entry: entry, localDeviceId: viewModel.localDeviceId)
            } else {
                Text("Clipboard history will appear here once you copy something.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry?.accessibilityDescription() ?? "No clipboard content yet")
    }
}

private struct HistorySectionView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @Binding var search: String
    @Binding var highlightedItemId: UUID?

    private var filteredItems: [ClipboardEntry] {
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            return viewModel.items
        }
        return viewModel.items.filter { $0.matches(query: search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search clipboard history")
                Button {
                    viewModel.clearHistory()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.items.isEmpty)
                .help("Clear clipboard history")
            }

            if filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No clipboard items")
                        .font(.headline)
                    Text(search.isEmpty ? "Copy something to get started." : "Try adjusting your search query.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                itemList
            }
        }
    }
    
    // Helper function to find TextField in view hierarchy
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

    @ViewBuilder
    private var itemList: some View {
        ScrollViewReader { proxy in
            scrollContent(proxy: proxy)
                .onChange(of: filteredItems.count) { newCount in
                    scrollToTopIfNeeded(proxy: proxy, hasItems: newCount > 0)
                }
                .onChange(of: filteredItems.first?.id) { _ in
                    scrollToTopIfNeeded(proxy: proxy, hasItems: !filteredItems.isEmpty)
                }
        }
    }
    
    @ViewBuilder
    private func scrollContent(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                    // Only show shortcut for items 2-10 (index 1-9)
                    // Item 1 (index 0) doesn't need shortcut as it's already in clipboard
                    let shortcutIndex = index > 0 && index <= 9 ? index : nil
                    rowView(item: item, shortcutIndex: shortcutIndex)
                        .id(item.id) // Use consistent ID - item.id for all items
                }
            }
        }
    }
    
    private func scrollToTopIfNeeded(proxy: ScrollViewProxy, hasItems: Bool) {
        if hasItems, let firstItem = filteredItems.first {
            withAnimation {
                proxy.scrollTo(firstItem.id, anchor: UnitPoint.top)
            }
        }
    }
    
    private func scrollToTop(proxy: ScrollViewProxy, hasItems: Bool) {
        if hasItems, let firstItem = filteredItems.first {
            withAnimation {
                proxy.scrollTo(firstItem.id, anchor: UnitPoint.top)
            }
        }
    }

    @ViewBuilder
    private func rowView(item: ClipboardEntry, shortcutIndex: Int?) -> some View {
        let isKeyboardHighlighted = highlightedItemId == item.id
        ClipboardRow(
            entry: item,
            viewModel: viewModel,
            shortcutIndex: shortcutIndex,
            isHighlighted: isKeyboardHighlighted,
            onHighlight: {
                highlightedItemId = item.id
            }
        )
        .padding(4)
    }
}

private struct ClipboardCard: View {
    private let logger = HypoLogger(category: "ClipboardCard")
    let entry: ClipboardEntry
    let localDeviceId: String
    @State private var showFullContent = false
    
    private func openFileInFinder(entry: ClipboardEntry) {
        guard case .file(let fileMetadata) = entry.content else { return }
        
        // Prefer original file URL when available (local-origin entries),
        // to avoid creating additional copies on disk.
        if let url = fileMetadata.url {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            return
        }
        
        guard let base64 = fileMetadata.base64,
              let data = Data(base64Encoded: base64) else { return }
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = fileMetadata.fileName
        let fileExtension = (fileName as NSString).pathExtension
        let fullFileName = fileExtension.isEmpty ? fileName : "\(fileName).\(fileExtension)"
        let tempURL = tempDir.appendingPathComponent(fullFileName)
        
        do {
            try data.write(to: tempURL)
            // Open in Finder
            NSWorkspace.shared.selectFile(tempURL.path, inFileViewerRootedAtPath: "")
            // Clean up temp file after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            logger.error("❌ Failed to create temp file for Finder: \(error.localizedDescription)")
        }
    }
    
    private func openLinkInBrowser(entry: ClipboardEntry) {
        guard case .link(let url) = entry.content else { return }
        NSWorkspace.shared.open(url)
    }
    
    private var originName: String {
        entry.originDisplayName(localDeviceId: localDeviceId)
    }
    
    private var isLocal: Bool {
        entry.isLocal(localDeviceId: localDeviceId)
    }
    
    private var isTruncated: Bool {
        switch entry.content {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Check if preview text is shorter than full text (preview adds "…" when truncated)
            let preview = entry.previewText
            return preview.count < trimmed.count || preview.hasSuffix("…")
        case .link(let url):
            let urlString = url.absoluteString
            let preview = entry.previewText
            // Check if preview text is shorter than full URL (preview adds "…" when truncated)
            return preview.count < urlString.count || preview.hasSuffix("…")
        case .image:
            return true  // Images always show detail view
        case .file:
            return false  // Files open in Finder, not detail view
        }
    }
    
    private var isMarkdown: Bool {
        switch entry.content {
        case .text(let text):
            // Simple markdown detection: check for common markdown patterns
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.contains("# ") || 
                   trimmed.contains("## ") || 
                   trimmed.contains("### ") ||
                   trimmed.contains("**") ||
                   trimmed.contains("* ") ||
                   trimmed.contains("- ") ||
                   trimmed.contains("```") ||
                   trimmed.contains("`")
        default:
            return false
        }
    }
    
    private var fullContentText: String {
        switch entry.content {
        case .text(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .link(let url):
            return url.absoluteString
        case .image(let metadata):
            if let fileName = metadata.altText {
                return "\(fileName) · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
            } else {
                return "Image · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
            }
        case .file(let metadata):
            return "\(metadata.fileName) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: entry.content.iconName)
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.content.title)
                            .font(.headline)
                        // Origin badge with icons
                        HStack(spacing: 4) {
                            // Encryption icon (shield)
                            if entry.isEncrypted {
                                Image(systemName: "shield.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.blue)
                                    .help("Encrypted")
                            }
                            // Transport origin icon (cloud only - no icon for LAN)
                            if let transportOrigin = entry.transportOrigin, transportOrigin == .cloud {
                                Image(systemName: "cloud.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .help("Via cloud relay")
                            }
                            // Origin name
                            Text(originName)
                                .font(.caption)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isLocal ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.2))
                        )
                        .foregroundStyle(isLocal ? .blue : .secondary)
                    }
                    // Show preview text with magnetic icon if truncated or previewable
                    HStack(alignment: .top, spacing: 4) {
                        Text(entry.previewText)
                            .lineLimit(3)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        // Show preview button for:
                        // - Truncated text (long text)
                        // - Images (always show detail view)
                        // - Files (open in Finder)
                        let shouldShowButton: Bool = {
                            switch entry.content {
                            case .text, .link:
                                return isTruncated || isMarkdown
                            case .image:
                                return true  // Always show for images
                            case .file:
                                return true  // Always show for files
                            }
                        }()
                        
                        if shouldShowButton {
                            Button(action: { 
                                switch entry.content {
                                case .file:
                                    openFileInFinder(entry: entry)
                                case .link:
                                    openLinkInBrowser(entry: entry)
                                case .image, .text:
                                    showFullContent = true
                                }
                            }) {
                                Image(systemName: {
                                    switch entry.content {
                                    case .file:
                                        return "folder"  // Folder icon for "Open in Finder"
                                    case .link:
                                        return "safari"  // Safari icon for "Visit in Browser"
                                    case .image, .text:
                                        return "eye"  // Eye icon for "View Detail/Preview"
                                    }
                                }())
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                            .help({
                                switch entry.content {
                                case .file:
                                    return "Open in Finder"
                                case .link:
                                    return "Visit in Browser"
                                case .image, .text:
                                    return "View Detail"
                                }
                            }())
                        }
                    }
                    .popover(isPresented: $showFullContent, arrowEdge: .trailing) {
                        ClipboardDetailWindow(entry: entry, isPresented: $showFullContent)
                            .frame(width: 600, height: 500)
                    }
                }
                Spacer()
            }
            Text(entry.timestamp.formatted(date: .numeric, time: .standard))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityDescription())
    }
}

private struct ClipboardRow: View {
    private let logger = HypoLogger(category: "ClipboardRow")
    let entry: ClipboardEntry
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    let shortcutIndex: Int?  // Optional: 1-9 for items 2-10, nil for first item
    let isHighlighted: Bool  // For keyboard shortcuts (Alt+index)
    let onHighlight: () -> Void
    @State private var showFullContent = false
    @State private var isHovered = false
    
    private func openFileInFinder(entry: ClipboardEntry) {
        guard case .file(let fileMetadata) = entry.content else { return }
        
        // Prefer original file URL when available (local-origin entries),
        // to avoid creating additional copies on disk.
        if let url = fileMetadata.url {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            return
        }
        
        guard let base64 = fileMetadata.base64,
              let data = Data(base64Encoded: base64) else { return }
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = fileMetadata.fileName
        let fileExtension = (fileName as NSString).pathExtension
        let fullFileName = fileExtension.isEmpty ? fileName : "\(fileName).\(fileExtension)"
        let tempURL = tempDir.appendingPathComponent(fullFileName)
        
        do {
            try data.write(to: tempURL)
            // Open in Finder
            NSWorkspace.shared.selectFile(tempURL.path, inFileViewerRootedAtPath: "")
            // Clean up temp file after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        } catch {
            logger.error("❌ Failed to create temp file for Finder: \(error.localizedDescription)")
        }
    }
    
    private func openLinkInBrowser(entry: ClipboardEntry) {
        guard case .link(let url) = entry.content else { return }
        NSWorkspace.shared.open(url)
    }
    
    private var originName: String {
        entry.originDisplayName(localDeviceId: viewModel.localDeviceId)
    }
    
    private var isLocal: Bool {
        entry.isLocal(localDeviceId: viewModel.localDeviceId)
    }
    
    private var isTruncated: Bool {
        switch entry.content {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Check if preview text is shorter than full text (preview adds "…" when truncated)
            let preview = entry.previewText
            return preview.count < trimmed.count || preview.hasSuffix("…")
        case .link(let url):
            let urlString = url.absoluteString
            let preview = entry.previewText
            // Check if preview text is shorter than full URL (preview adds "…" when truncated)
            return preview.count < urlString.count || preview.hasSuffix("…")
        case .image:
            return true  // Images always show detail view
        case .file:
            return false  // Files open in Finder, not detail view
        }
    }
    
    private var isMarkdown: Bool {
        switch entry.content {
        case .text(let text):
            // Simple markdown detection: check for common markdown patterns
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.contains("# ") || 
                   trimmed.contains("## ") || 
                   trimmed.contains("### ") ||
                   trimmed.contains("**") ||
                   trimmed.contains("* ") ||
                   trimmed.contains("- ") ||
                   trimmed.contains("```") ||
                   trimmed.contains("`")
        default:
            return false
        }
    }
    
    private var fullContentText: String {
        switch entry.content {
        case .text(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .link(let url):
            return url.absoluteString
        case .image(let metadata):
            if let fileName = metadata.altText {
                return "\(fileName) · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
            } else {
                return "Image · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
            }
        case .file(let metadata):
            return "\(metadata.fileName) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center) {
                // Left column: Icon and keyboard shortcut index (only for items 2-10)
                VStack(alignment: .center, spacing: 2) {
                    Image(systemName: entry.content.iconName)
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    // Alt+index shortcut label (only show for items 2-10)
                    if let shortcutIndex = shortcutIndex {
                        Text("⌥\(shortcutIndex)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Option \(shortcutIndex) shortcut")
                    } else {
                        // Spacer to maintain alignment
                        Text("")
                            .font(.system(size: 9))
                    }
                }
                .frame(width: 32)
                
                // Middle column: Content description
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.content.title)
                            .font(.headline)
                        // Origin badge with icons
                        HStack(spacing: 4) {
                            // Encryption icon (shield)
                            if entry.isEncrypted {
                                Image(systemName: "shield.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.blue)
                                    .help("Encrypted")
                            }
                            // Transport origin icon (cloud only - no icon for LAN)
                            if let transportOrigin = entry.transportOrigin, transportOrigin == .cloud {
                                Image(systemName: "cloud.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .help("Via cloud relay")
                            }
                            // Origin name
                            Text(originName)
                                .font(.caption)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isLocal ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.2))
                        )
                        .foregroundStyle(isLocal ? .blue : .secondary)
                    }
                    // Preview text (no icon here - moved to right column)
                    Text(entry.previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                // Right column: Time, pinned status, and preview/finder icon
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button(action: { 
                        // Ensure pin toggle works for all items, including the first one
                        viewModel.togglePin(entry) 
                    }) {
                        Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.fill" : "pin")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(entry.isPinned ? .orange : .secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(entry.isPinned ? "Unpin this item" : "Pin this item")
                    // Preview/finder icon moved here
                    let shouldShowButton: Bool = {
                        switch entry.content {
                        case .text, .link:
                            return isTruncated || isMarkdown
                        case .image:
                            return true  // Always show for images
                        case .file:
                            return true  // Always show for files
                        }
                    }()
                    
                    if shouldShowButton {
                        Button(action: { 
                            switch entry.content {
                            case .file:
                                openFileInFinder(entry: entry)
                            case .link:
                                openLinkInBrowser(entry: entry)
                            case .image, .text:
                                showFullContent = true
                            }
                        }) {
                            Image(systemName: {
                                switch entry.content {
                                case .file:
                                    return "folder"  // Folder icon for "Open in Finder"
                                case .link:
                                    return "safari"  // Safari icon for "Visit in Browser"
                                case .image, .text:
                                    return "eye"  // Eye icon for "View Detail/Preview"
                                }
                            }())
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .help({
                            switch entry.content {
                            case .file:
                                return "Open in Finder"
                            case .link:
                                return "Visit in Browser"
                            case .image, .text:
                                return "View Detail"
                            }
                        }())
                    }
                }
                .popover(isPresented: $showFullContent, arrowEdge: .trailing) {
                    ClipboardDetailWindow(entry: entry, isPresented: $showFullContent)
                        .frame(width: 600, height: 500)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((isHovered || isHighlighted) ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke((isHovered || isHighlighted) ? Color.accentColor : (entry.isPinned ? Color.accentColor : Color.clear), lineWidth: (isHovered || isHighlighted) ? 2 : 1)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isHighlighted)
        .contextMenu {
            Button("Copy") { viewModel.copyToPasteboard(entry) }
            Button(entry.isPinned ? "Unpin" : "Pin") { viewModel.togglePin(entry) }
            Button("Delete", role: .destructive) {
                Task { await viewModel.remove(id: entry.id) }
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            // Copy then auto-paste (will prompt Accessibility once; falls back to copy-only if denied)
            viewModel.copyToPasteboard(entry)
            HistoryPopupPresenter.shared.hideAndRestoreFocus {
                pasteToCursorAtCurrentPosition(entry: entry)
            }
        }
        .onDrag {
            if let provider = viewModel.itemProvider(for: entry) {
                return provider
            }
            return NSItemProvider(object: entry.previewText as NSString)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityDescription())
    }
}

private struct SettingsSectionView: View {
    private let logger = HypoLogger(category: "SettingsSectionView")
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @State private var isPresentingPairing = false
    @State private var localHistoryLimit: Double = 200
    @State private var historyLimitUpdateTask: Task<Void, Never>?
    
    var body: some View {
        ScrollView {
            Form {
                Section("Connection") {
                    HStack {
                        Text("Status")
                        Spacer()
                        // Connection Status Icon
                        Image(systemName: connectionStatusIconName(for: viewModel.connectionState))
                            .foregroundColor(connectionStatusIconColor(for: viewModel.connectionState))
                            .font(.system(size: 14, weight: .medium))
                            .help(connectionStatusTooltip(for: viewModel.connectionState))
                    }
                }
                
                Section("Security") {
                    Toggle("Plain Text Mode", isOn: Binding(
                        get: { viewModel.plainTextModeEnabled },
                        set: { viewModel.plainTextModeEnabled = $0 }
                    ))
                }

                Section("History") {
                    HStack {
                        Slider(value: Binding(
                            get: { localHistoryLimit },
                            set: { newValue in
                                localHistoryLimit = newValue
                                // Cancel any pending update
                                historyLimitUpdateTask?.cancel()
                                // Debounce the update - only apply after 0.3 seconds of no changes
                                historyLimitUpdateTask = Task {
                                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
                                    if !Task.isCancelled {
                                        await MainActor.run {
                                            viewModel.updateHistoryLimit(Int(newValue))
                                        }
                                    }
                                }
                            }
                        ), in: 20...500, step: 10) {
                            Text("History size")
                        }
                        Text("\(Int(localHistoryLimit))")
                            .frame(width: 50, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    .onAppear {
                        localHistoryLimit = Double(viewModel.historyLimit)
                    }
                    .onChange(of: viewModel.historyLimit) { newValue in
                        // Update local value when viewModel changes (e.g., from external source)
                        if abs(localHistoryLimit - Double(newValue)) > 1 {
                            localHistoryLimit = Double(newValue)
                        }
                    }
                    Toggle("Auto-delete after a delay", isOn: Binding(
                        get: { viewModel.autoDeleteAfterHours > 0 },
                        set: { newValue in
                            let hours = newValue ? max(viewModel.autoDeleteAfterHours, 6) : 0
                            viewModel.setAutoDelete(hours: hours)
                        }
                    ))
                    if viewModel.autoDeleteAfterHours > 0 {
                        Stepper(value: Binding(
                            get: { viewModel.autoDeleteAfterHours },
                            set: { viewModel.setAutoDelete(hours: $0) }
                        ), in: 1...72, step: 1) {
                            Text("Delete after \(viewModel.autoDeleteAfterHours) hour(s)")
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: Binding(
                        get: { viewModel.appearancePreference },
                        set: { viewModel.updateAppearance($0) }
                    )) {
                        ForEach(ClipboardHistoryViewModel.AppearancePreference.allCases) { appearance in
                            Text(appearanceTitle(for: appearance)).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                #if canImport(UserNotifications)
                Section("Notifications") {
                    NotificationPermissionSection()
                }
                #endif
                
                #if canImport(AppKit)
                Section("Accessibility") {
                    AccessibilityPermissionSection()
                }
                #endif

                Section("Paired devices") {
                    if viewModel.pairedDevices.isEmpty {
                        Text("No devices paired yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.pairedDevices) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(device.name)
                                            .help(deviceTooltip(for: device))
                                        PlatformBadge(platform: device.platform)
                                    }
                                    Text(connectionStatusText(for: device))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Circle()
                                    .fill(device.isOnline ? Color.green : Color.gray)
                                    .frame(width: 10, height: 10)
                                    .accessibilityLabel(device.isOnline ? "Online" : "Offline")
                                    .id("\(device.id)-\(device.isOnline)") // Force re-render when isOnline changes
                                    .onChange(of: device.isOnline) { newValue in
                                        logger.debug("🔄 [UI] Device \(device.name) isOnline changed to: \(newValue)")
                                    }
                                    .onAppear {
                                        logger.debug("🎨 [UI] Device \(device.name) rendered: isOnline=\(device.isOnline), id=\(device.id)")
                                    }
                                    .help(deviceTooltip(for: device))
                                Button(role: .destructive) {
                                    viewModel.removePairedDevice(device)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Remove device")
                            }
                            .help("Device ID: \(device.id)")
                        }
                    }
                    Button("Pair new device") { isPresentingPairing = true }
                }
                .onAppear {
                    // Trigger connection status probe when settings section appears to refresh peer status
                    if let transportManager = viewModel.transportManager {
                        Task {
                            await transportManager.probeConnectionStatus()
                        }
                    }
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hypo Clipboard")
                            .font(.headline)
                        Text(versionString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .formStyle(.grouped)
        }
        .sheet(isPresented: $isPresentingPairing) {
            PairDeviceSheet(viewModel: viewModel, isPresented: $isPresentingPairing)
        }
    }
    
    private var versionString: String {
        let bundle = Bundle.main
        
        // Determine build configuration (Debug or Release) by checking bundle path
        // Release builds use HypoApp-release.app, debug builds use HypoApp.app
        let bundlePath = bundle.bundlePath
        let buildConfig = bundlePath.contains("-release") ? "Release" : "Debug"
        
        if let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = bundle.infoDictionary?["CFBundleVersion"] as? String {
            return "Version \(version)-\(buildConfig) (Build \(build))"
        } else if let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
            return "Version \(version)-\(buildConfig)"
        } else if let build = bundle.infoDictionary?["CFBundleVersion"] as? String {
            return "Build \(build) (\(buildConfig))"
        } else {
            // Log warning only if version info is missing (unexpected)
            logger.warning("⚠️ [SettingsSectionView] Version info missing from bundle: path=\(bundle.bundlePath), identifier=\(bundle.bundleIdentifier ?? "nil")")
            return "Version 1.0.0-\(buildConfig)"
        }
    }

    private func appearanceTitle(for appearance: ClipboardHistoryViewModel.AppearancePreference) -> String {
        switch appearance {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    
    private func connectionStatusIconName(for state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            return "cloud.slash.fill" // Cloud with slash when disconnected (not wifi)
        case .connectingLan, .connectingCloud:
            return "arrow.triangle.2.circlepath"
        case .connectedLan:
            return "wifi"
        case .connectedCloud:
            return "cloud.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private func connectionStatusIconColor(for state: ConnectionState) -> Color {
        switch state {
        case .disconnected:
            return .gray
        case .connectingLan, .connectingCloud:
            return .orange
        case .connectedLan:
            return .green
        case .connectedCloud:
            return .blue
        case .error:
            return .red
        }
    }
    
    private func connectionStatusTooltip(for state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            return "Server Offline"
        case .connectingLan:
            return "Connecting via LAN..."
        case .connectedLan:
            return "Connected via LAN"
        case .connectingCloud:
            return "Connecting via Cloud..."
        case .connectedCloud:
            return "Connected via Cloud"
        case .error:
            return "Connection Error"
        }
    }
    
    private struct PlatformBadge: View {
        let platform: String
        
        var body: some View {
            Text(platformIcon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(platformColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(platformColor.opacity(0.15))
                )
        }
        
        private var platformIcon: String {
            switch platform.lowercased() {
            case "android":
                return "🤖"
            case "ios", "iphone", "ipad":
                return "📱"
            case "macos", "mac":
                return "💻"
            default:
                return "📱"
            }
        }
        
        private var platformColor: Color {
            switch platform.lowercased() {
            case "android":
                return .green
            case "ios", "iphone", "ipad":
                return .blue
            case "macos", "mac":
                return .blue
            default:
                return .secondary
            }
        }
    }
    
    private func connectionStatusText(for device: PairedDevice) -> String {
        guard device.isOnline else {
            // Offline - show last seen time
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return "Last seen \(formatter.string(from: device.lastSeen))"
        }
        
        // Device is online - determine connection method
        // Match Android's logic: show "and server" if device is discovered on LAN AND server is connected
        let isServerConnected = viewModel.connectionState == .connectedCloud
        
        // ALWAYS check current discovery state first (not just stored values)
        // This ensures we show IP even if device was just discovered and not yet updated in storage
        var discoveredPeerHost: String? = nil
        var discoveredPeerPort: Int? = nil
        if let transportManager = viewModel.transportManager {
            let discoveredPeers = transportManager.lanDiscoveredPeers()
            if let peer = discoveredPeers.first(where: { peer in
                if let peerDeviceId = peer.endpoint.metadata["device_id"] {
                    return peerDeviceId.lowercased() == device.id.lowercased()
                }
                return false
            }) {
                discoveredPeerHost = peer.endpoint.host
                discoveredPeerPort = peer.endpoint.port
            }
        }
        
        // Get device transport to determine if it's using cloud (for cloud-only case)
        var deviceTransport: TransportChannel? = nil
        if let transportManager = viewModel.transportManager {
            deviceTransport = transportManager.lastSuccessfulTransport(for: device.id)
                ?? transportManager.lastSuccessfulTransport(for: device.name)
                ?? (device.serviceName != nil ? transportManager.lastSuccessfulTransport(for: device.serviceName!) : nil)
        }
        let isCloudTransport = deviceTransport == .cloud && isServerConnected
        
        // Use current discovery info if available, otherwise fall back to stored values
        // Priority: current discovery > stored bonjour info
        let effectiveHost = discoveredPeerHost ?? device.bonjourHost
        let effectivePort = discoveredPeerPort ?? device.bonjourPort
        let hasEffectiveLan = effectiveHost != nil && effectivePort != nil && effectiveHost != "unknown"
        
        if hasEffectiveLan {
            // We have LAN info - show IP:PORT
            if let host = effectiveHost, let port = effectivePort {
                if isServerConnected {
                    // Connected via both LAN and server
                    return "Connected via \(host):\(port) and server"
                } else {
                    // Connected via LAN only
                    return "Connected via \(host):\(port)"
                }
            }
        }
        
        // No LAN info - check cloud connection
        if isServerConnected {
            // Server is connected and device is online but no LAN info
            // This means device is reachable via cloud (even if we don't have a transport record yet)
            return "Connected via server"
        } else if isCloudTransport {
            // Connected via cloud only (device has cloud transport record)
            return "Connected via server"
        }
        
        // Fallback: device is online but we don't know how it's connected
        // This should rarely happen - only if:
        // 1. Device is online (has active connection or is discovered)
        // 2. No LAN info (bonjourHost/bonjourPort not set and not currently discovered)
        // 3. Server is not connected
        // 4. No cloud transport record
        // This could happen if there's a timing issue where the device status is updated before connection details
        return "Connected"
    }
    
    private func deviceTooltip(for device: PairedDevice) -> String {
        var tooltip = "Device: \(device.name)\n"
        tooltip += "Platform: \(device.platform)\n"
        tooltip += "Device ID: \(device.id)\n"
        tooltip += "Status: \(device.isOnline ? "Online" : "Offline")\n"
        
        if !device.isOnline {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            tooltip += "Last seen: \(formatter.string(from: device.lastSeen))"
        } else {
            tooltip += "Connection: \(connectionStatusText(for: device))"
            
            // Add LAN details if available
            if let host = device.bonjourHost, let port = device.bonjourPort, host != "unknown" {
                tooltip += "\nLAN: \(host):\(port)"
            }
            
            // Add service name if available
            if let serviceName = device.serviceName {
                tooltip += "\nService: \(serviceName)"
            }
        }
        
        return tooltip
    }
}

#if canImport(UserNotifications)
import UserNotifications

private struct NotificationPermissionSection: View {
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isChecking = true
    
    var body: some View {
        Group {
            HStack {
                Text("Permission")
                Spacer()
                if isChecking {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    statusText
                }
            }
            
            if authorizationStatus == .denied {
                Button("Open System Settings") {
                    openSystemSettings()
                }
                .buttonStyle(.bordered)
            } else if authorizationStatus == .notDetermined {
                Text("Notifications will be requested when needed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            checkAuthorizationStatus()
        }
    }
    
    private var statusText: some View {
        Group {
            switch authorizationStatus {
            case .authorized, .provisional:
                Label("Enabled", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .denied:
                Label("Disabled", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
            case .notDetermined:
                Label("Not Set", systemImage: "questionmark.circle")
                    .foregroundColor(.orange)
            @unknown default:
                Label("Unknown", systemImage: "questionmark.circle")
                    .foregroundColor(.gray)
            }
        }
    }
    
    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func checkAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                authorizationStatus = settings.authorizationStatus
                isChecking = false
            }
        }
    }
}
#endif

#if canImport(AppKit)
private struct AccessibilityPermissionSection: View {
    @State private var isAccessibilityEnabled = false
    @State private var isChecking = true
    
    var body: some View {
        Group {
            HStack {
                Text("Permission")
                Spacer()
                if isChecking {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    statusText
                }
            }
            
            if !isAccessibilityEnabled {
                Button("Open System Settings") {
                    openSystemSettings()
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear {
            checkAccessibilityStatus()
        }
    }
    
    private var statusText: some View {
        Group {
            if isAccessibilityEnabled {
                Label("Enabled", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Label("Disabled", systemImage: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
        }
    }
    
    private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func checkAccessibilityStatus() {
        // Check accessibility permissions without prompting
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let isEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        DispatchQueue.main.async {
            isAccessibilityEnabled = isEnabled
            isChecking = false
        }
    }
}
#endif

private struct PairDeviceSheet: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @Binding var isPresented: Bool
    @StateObject private var remoteViewModel: RemotePairingViewModel
    @State private var hasStarted = false

    init(viewModel: ClipboardHistoryViewModel, isPresented: Binding<Bool>) {
        self._viewModel = ObservedObject(initialValue: viewModel)
        self._isPresented = isPresented
        _remoteViewModel = StateObject(wrappedValue: viewModel.makeRemotePairingViewModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair New Device")
                .font(.title2.bold())

            statusSection

            content

            Divider()
            
            HStack {
                Button("Close") { 
                    isPresented = false 
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if isComplete {
                    Button("Done") { 
                        isPresented = false 
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 350, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled()
        .onAppear { startIfNeeded() }
        .onDisappear {
            remoteViewModel.reset()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Text(remoteViewModel.statusMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
        if let countdown = remoteViewModel.countdownText {
            Text(countdown)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        remoteContent
    }

    private var isComplete: Bool {
        if case .completed = remoteViewModel.state { return true }
        return false
    }

    @ViewBuilder
    private var remoteContent: some View {
        switch remoteViewModel.state {
        case .idle, .requestingCode:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .displaying(let code, _), .awaitingChallenge(let code, _):
            VStack(spacing: 16) {
                Text("Pairing Code")
                    .font(.headline)
                Text(code)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(12)
                Text("Enter this code on your Android device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .completing:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .completed:
            successView
        case .failed(let message):
            failureView(message: message)
        }
    }

    @ViewBuilder
    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Pairing complete")
                .font(.title3)
                .bold()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func startIfNeeded(force: Bool = false) {
        let params = viewModel.pairingParameters()
        if force || !hasStarted {
            remoteViewModel.start(service: params.service, port: params.port, relayHint: params.relayHint)
        }
        hasStarted = true
    }
}

private struct ConnectionStatusView: View {
    let state: ConnectionState
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.system(size: 14, weight: .medium))
            Text(statusText)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(iconColor.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var iconName: String {
        switch state {
        case .disconnected:
            return "cloud.slash.fill" // Cloud with slash when disconnected (not wifi)
        case .connectingLan, .connectingCloud:
            return "arrow.triangle.2.circlepath"
        case .connectedLan:
            return "wifi"
        case .connectedCloud:
            return "cloud.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var iconColor: Color {
        switch state {
        case .disconnected:
            return .gray
        case .connectingLan, .connectingCloud:
            return .orange
        case .connectedLan:
            return .green
        case .connectedCloud:
            return .blue
        case .error:
            return .red
        }
    }
    
    private var statusText: String {
        switch state {
        case .disconnected:
            return "Offline"
        case .connectingLan:
            return "Connecting (LAN)..."
        case .connectedLan:
            return "Connected (LAN)"
        case .connectingCloud:
            return "Connecting (Cloud)..."
        case .connectedCloud:
            return "Connected (Cloud)"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

// Detail window for showing full clipboard content
private struct ClipboardDetailWindow: View {
    let entry: ClipboardEntry
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(entry.content.title)
                    .font(.headline)
                Spacer()
                Button("Close") {
                    // Close the popover - this won't dismiss the parent window
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch entry.content {
                    case .text(let text):
                        Text(text)
                            .textSelection(.enabled)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        
                    case .link(let url):
                        Link(url.absoluteString, destination: url)
                            .font(.body)
                            .padding()
                        
                    case .image(let metadata):
                        ImageDetailView(metadata: metadata)
                        
                    case .file(let metadata):
                        FileDetailView(metadata: metadata)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// Image detail view with async loading for image files
private struct ImageDetailView: View {
    let metadata: ImageMetadata
    
    var body: some View {
        Group {
            if let imageData = metadata.data {
                // Try to create NSImage from raw data
                if let nsImage = NSImage(data: imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 800, maxHeight: 600)
                        .padding()
                } else {
                    // Failed to decode - show error with format info
                    VStack(spacing: 8) {
                        Text("⚠️ Failed to display image")
                            .font(.headline)
                        Text("Format: \(metadata.format.uppercased())")
                        Text("Size: \(metadata.byteSize.formatted(.byteCount(style: .binary)))")
                        Text("Data length: \(imageData.count) bytes")
                    }
                    .padding()
                }
            } else {
                // No image data available (shouldn't happen for pasteboard images, but handle gracefully)
                VStack(spacing: 16) {
                    if let fileName = metadata.altText {
                        Text("\(fileName) · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))")
                            .font(.headline)
                    } else {
                        Text("Image · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))")
                            .font(.headline)
                    }
                    if let thumbnail = metadata.thumbnail,
                       let thumbnailImage = NSImage(data: thumbnail) {
                        Image(nsImage: thumbnailImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 200, maxHeight: 200)
                            .padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
    }
}

// File detail view with save functionality and async loading
private struct FileDetailView: View {
    let metadata: FileMetadata
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var fileData: Data? = nil
    @State private var isLoading = false
    @State private var loadError: String? = nil
    
    private var isTextFile: Bool {
        let fileName = metadata.fileName.lowercased()
        let textExtensions = ["txt", "md", "json", "xml", "html", "css", "js", "py", "swift", "kt", "java", "c", "cpp", "h", "hpp", "sh", "yaml", "yml", "log", "csv"]
        return textExtensions.contains { fileName.hasSuffix(".\($0)") }
    }
    
    private var fileContent: String? {
        guard let data = fileData else { return nil }
        // Try UTF-8 first
        if let utf8 = String(data: data, encoding: .utf8), utf8.range(of: "\0") == nil {
            return utf8
        }
        // Try other encodings for text files
        if isTextFile {
            if let utf16 = String(data: data, encoding: .utf16) {
                return utf16
            }
        }
        return nil
    }
    
    private func loadFileAsync() {
        // If we already have base64 data, use it immediately
        if let base64 = metadata.base64,
           let data = Data(base64Encoded: base64) {
            fileData = data
            return
        }
        
        // If we have a URL, load it async
        guard let url = metadata.url else {
            loadError = "No file URL available"
            return
        }
        
        // Already loading or loaded
        if isLoading || fileData != nil {
            return
        }
        
        isLoading = true
        loadError = nil
        
        Task {
            do {
                // Use async file reading to avoid blocking on iCloud files
                let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            // Use mappedIfSafe for better performance with large files
                            let data = try Data(contentsOf: url, options: .mappedIfSafe)
                            continuation.resume(returning: data)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                
                await MainActor.run {
                    self.fileData = data
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // File info
            VStack(alignment: .leading, spacing: 8) {
                Text(metadata.fileName)
                    .font(.headline)
                Text("Size: \(metadata.byteSize.formatted(.byteCount(style: .binary)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let uti = metadata.uti as String? {
                    Text("Type: \(uti)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            // Save button
            Button(action: saveFile) {
                HStack {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(isSaving ? "Saving..." : "Save File")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
            
            if let error = saveError {
                Text("Error: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            Divider()
            
            // Content display with async loading
            Group {
                if isLoading {
                    // Loading state
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading file from iCloud...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                } else if let error = loadError {
                    // Error state
                    VStack(alignment: .leading, spacing: 8) {
                        Text("⚠️ Failed to load file")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            loadFileAsync()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else if let content = fileContent, isTextFile {
                    // Text file - show content
                    ScrollView {
                        Text(content)
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let data = fileData {
                    // Binary file - show hex preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Binary file content (hex preview):")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(hexDump(data: data, maxBytes: 1024))
                                .textSelection(.enabled)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if data.count > 1024 {
                            Text("(Showing first 1KB of \(data.count) bytes)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    // No data loaded yet - show load button or auto-load
                    Button("Load File") {
                        loadFileAsync()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .onAppear {
                // Auto-load when preview opens
                if fileData == nil && !isLoading && loadError == nil {
                    loadFileAsync()
                }
            }
        }
        .padding()
    }
    
    private func saveFile() {
        guard let data = fileData else {
            saveError = "No file data available"
            return
        }
        
        isSaving = true
        saveError = nil
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.data]
        savePanel.nameFieldStringValue = metadata.fileName
        savePanel.canCreateDirectories = true
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try data.write(to: url)
                    saveError = nil
                } catch {
                    saveError = error.localizedDescription
                }
            }
            isSaving = false
        }
    }
    
    private func hexDump(data: Data, maxBytes: Int) -> String {
        let bytesToShow = min(data.count, maxBytes)
        var result = ""
        for i in stride(from: 0, to: bytesToShow, by: 16) {
            let end = min(i + 16, bytesToShow)
            let chunk = data[i..<end]
            
            // Hex representation
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let padding = String(repeating: "   ", count: max(0, 16 - chunk.count))
            
            // ASCII representation
            let ascii = chunk.map { byte -> String in
                let char = Character(UnicodeScalar(byte))
                return char.isPrintable ? String(char) : "."
            }.joined()
            
            result += String(format: "%08x  %@%@  |%@|\n", i, hex, padding, ascii)
        }
        return result
    }
}

private extension Character {
    var isPrintable: Bool {
        return self.isASCII && (32...126).contains(self.asciiValue ?? 0)
    }
}
