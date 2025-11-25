#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
import Carbon
import ApplicationServices
#endif

// AppDelegate to ensure hotkey setup runs at app launch (not waiting for UI)
class HypoAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = HypoLogger(category: "HypoAppDelegate")
    private var hotKeyRef: EventHotKeyRef?
    private var altNumberHotKeys: [Int: EventHotKeyRef] = [:]
    private static var eventHandlerInstalled = false
    
    override init() {
        super.init()
        // Removed logging to reduce duplicates
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("🚀 [HypoAppDelegate] applicationDidFinishLaunching called")
        
        // Setup Hotkey using Carbon API (more reliable than CGEventTap)
        // Note: Carbon RegisterEventHotKey does NOT require Accessibility permissions
        setupCarbonHotkey()
    }
    
    func setupCarbonHotkey() {
        logger.info("🔧 setupCarbonHotkey() called")
        
        // Install event handler once (static check)
        if !Self.eventHandlerInstalled {
            logger.info("🔧 [HypoAppDelegate] Installing Carbon event handler...")
            
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
                NSLog("🔔 [HypoAppDelegate] Event handler callback invoked: err=\(err), id=\(hotKeyID.id), signature=\(hotKeyID.signature)")
                
                if err == noErr {
                    if hotKeyID.id == 1 {
                        // Alt+V - Show history popup
                        // Note: Can't use logger here as this is a C callback, use NSLog
                        NSLog("🎯 [HypoAppDelegate] HOTKEY TRIGGERED: Alt+V pressed")
                        
                        DispatchQueue.main.async {
                            NSApp.activate(ignoringOtherApps: true)
                            
                            if let viewModel = AppContext.shared.historyViewModel {
                                HistoryPopupPresenter.shared.show(with: viewModel)
                            }
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
                                    // Use NSLog for critical debugging, but minimize
                                    NSLog("🎯 [HypoAppDelegate] Alt+\(num) pressed, item: \(item.content.title)")
                                    
                                    // Highlight the item before copying (post notification for view to update)
                                    NotificationCenter.default.post(
                                        name: NSNotification.Name("HighlightHistoryItem"),
                                        object: nil,
                                        userInfo: ["itemId": item.id]
                                    )
                                    
                                    // Copy to clipboard first
                                    viewModel.copyToPasteboard(item)
                                    
                                    // Wait a moment for clipboard to be ready, then hide and paste
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        // Hide popup and restore focus, then paste
                                        HistoryPopupPresenter.shared.hideAndRestoreFocus {
                                            // Paste to cursor position after focus is restored
                                            pasteToCursorAtCurrentPosition()
                                        }
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
            logger.info("✅ [HypoAppDelegate] Event handler installed successfully")
        } else {
            logger.error("❌ [HypoAppDelegate] Failed to install Carbon event handler: \(installStatus)")
            return
        }
        }
        
        // Check if hotkey is already registered
        if self.hotKeyRef != nil {
            logger.info("ℹ️ [HypoAppDelegate] Hotkey already registered, skipping")
            return
        }
        
        // Register hotkey: Alt+V (keyCode 9 = 'V')
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4859504F) // "HYPO" signature
        hotKeyID.id = 1
        
        var hotKeyRef: EventHotKeyRef?
        let keyCode = UInt32(9) // 'V' key
        let modifiers = UInt32(optionKey) // Alt/Option
        
        logger.info("🔧 [HypoAppDelegate] Registering hotkey: keyCode=\(keyCode), modifiers=\(modifiers), signature=\(hotKeyID.signature), id=\(hotKeyID.id)")
        
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
            logger.info("✅ [HypoAppDelegate] Carbon hotkey registered: Alt+V (status: \(status), ref: \(hotKey))")
        } else if self.hotKeyRef == nil {
            // Only log error if hotkey wasn't already registered
            logger.warning("⚠️ [HypoAppDelegate] Hotkey registration returned status=\(status) (may already be registered). Ref: \(hotKeyRef != nil ? "exists" : "nil")")
            
            // If registration failed but we don't have a ref, try to unregister any existing hotkey first
            if status == -9878 { // eventHotKeyExistsErr
                logger.info("🔄 [HypoAppDelegate] Hotkey already exists, attempting to unregister and re-register...")
                // Note: We can't unregister without the ref, so we'll just log this
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
                logger.info("✅ [HypoAppDelegate] Carbon hotkey registered: Alt+\(num) (status: \(status))")
            } else {
                logger.warning("⚠️ [HypoAppDelegate] Failed to register Alt+\(num): status=\(status)")
            }
        }
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

// Standalone function to paste at cursor (can be called from C callbacks)
private func pasteToCursorAtCurrentPosition() {
    let logger = HypoLogger(category: "pasteToCursor")
    
    // Additional delay to ensure focus is fully restored and clipboard is ready
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        logger.info("📋 Attempting to paste...")
        
        // Use global event tap - more reliable than postToPid
        // Create key down event for 'V' with Cmd modifier
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true) else {
            logger.error("❌ Failed to create keyDown event")
            return
        }
        keyDownEvent.flags = .maskCommand
        
        // Post to HID event tap (this sends to the frontmost app)
        _ = keyDownEvent.post(tap: .cghidEventTap)
        logger.info("📋 KeyDown posted")
        
        // Small delay between key down and key up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            guard let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
                logger.error("❌ Failed to create keyUp event")
                return
            }
            keyUpEvent.flags = .maskCommand
            _ = keyUpEvent.post(tap: .cghidEventTap)
            logger.info("✅ KeyUp posted")
        }
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
        
        logger.info("🚀 [HypoMenuBarApp] About to call setHistoryViewModel")
        
        transportManager.setHistoryViewModel(viewModel)
        
        logger.info("🚀 [HypoMenuBarApp] setHistoryViewModel completed")
        
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
        MenuBarExtra("Hypo", systemImage: "clipboard") {
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
                    
                    // CRITICAL: Ensure setHistoryViewModel is called when view appears
                    if let transportManager = viewModel.transportManager {
                        transportManager.setHistoryViewModel(viewModel)
                    }
                    
                    setupMonitor()
                    // Global shortcut registration is handled by HypoAppDelegate (Carbon hotkey)
                }
                .onDisappear {
                    // Keep the global shortcut active across menu open/close cycles.
                }
                .task {
                    // Also call it from .task as backup
                    if let transportManager = viewModel.transportManager {
                        logger.info("🚀 [HypoMenuBarApp] .task: Ensuring setHistoryViewModel is called")
                        transportManager.setHistoryViewModel(viewModel)
                    }
                    await viewModel.start()
                }
                .onOpenURL { url in
                    Task { await viewModel.handleDeepLink(url) }
                }
                .background(MenuBarIconRightClickHandler(viewModel: viewModel))
        }
        .menuBarExtraStyle(.window)
    }
    
    private func setupRightClickMenu() {
        // Set up right-click menu after MenuBarExtra creates the status item
        // Right-click handling disabled (status item uses default behavior)
    }

    private func setupMonitor() {
        guard monitor == nil else { return }
        let deviceIdentity = DeviceIdentity()
        let monitor = ClipboardMonitor(
            deviceId: deviceIdentity.deviceId,
            platform: deviceIdentity.platform,
            deviceName: deviceIdentity.deviceName
        )
        monitor.delegate = viewModel
        monitor.start()
        self.monitor = monitor
    }
    
    private func setupGlobalShortcut() {
        // Using Shift+Cmd+V (V for View/History) to avoid system shortcut conflicts
        // Shift+Cmd+C conflicts with Terminal/Color Picker system shortcuts
        
        // Avoid duplicate setup
        if globalShortcutMonitor != nil {
            logger.info("ℹ️ [HypoMenuBarApp] Global shortcut already set up, skipping")
            return
        }
        
        logger.info("🔧 [HypoMenuBarApp] setupGlobalShortcut() called - Using Shift+Cmd+V")
        
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
        
        logger.info("🔧 [HypoMenuBarApp] Setting up NSEvent shortcut for Shift+Cmd+V")
        
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
                logger.info("🎯 [NSEvent] Intercepted Shift+Cmd+V - showing popup")
                
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
        
        // Global monitor (works system-wide, requires accessibility permissions)
        _ = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if event.modifierFlags.contains(.command) &&
               event.modifierFlags.contains(.shift) &&
               key == "v" {
                logger.info("🎯 [NSEvent Global] Intercepted Shift+Cmd+V - showing popup")
                
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.showHistoryPopup()
                    }
                }
            }
        }
        
        logger.info("✅ [HypoMenuBarApp] NSEvent shortcut registered: Shift+Cmd+V")
    }
    
    private func showHistoryPopup() {
        logger.info("📢 [HypoMenuBarApp] showHistoryPopup() called - posting notifications")
        
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
        
        logger.info("✅ [HypoMenuBarApp] Notifications posted: ShowHistoryPopup, ShowHistorySection")
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
        .onAppear {
            isVisible = true
            windowPinned = HistoryPopupPresenter.shared.pinned
            if historyOnly { selectedSection = .history }
            // Trigger connection status probe when window appears to refresh peer status
            if let transportManager = viewModel.transportManager {
                Task {
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
        
        // Add global event monitor for Alt+1 through Alt+9
        // These map to items 2-10 (skip first item which is already in clipboard)
        // Use both local and global monitors to ensure events are captured
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Only handle when history section is selected
            guard self.selectedSection == .history else { return event }
            
            // Check for Alt+number (1-9)
            if event.modifierFlags.contains(.option) {
                let keyCode = event.keyCode
                // Key codes: 18=1, 19=2, 20=3, 21=4, 23=5, 22=6, 26=7, 28=8, 25=9
                let numberKeyCodes: [UInt16: Int] = [
                    18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
                    22: 6, 26: 7, 28: 8, 25: 9
                ]
                
                if let num = numberKeyCodes[keyCode] {
                    self.logger.info("🎯 [MenuBarContentView] Alt+\(num) pressed")
                    
                    // Get filtered items (same logic as HistorySectionView)
                    let filteredItems: [ClipboardEntry] = {
                        if self.search.trimmingCharacters(in: .whitespaces).isEmpty {
                            return self.viewModel.items
                        }
                        return self.viewModel.items.filter { $0.matches(query: self.search) }
                    }()
                    
                    // Alt+1 maps to item 2 (index 1), Alt+2 maps to item 3 (index 2), etc.
                    // Skip first item (index 0) as it's already in clipboard
                    let itemIndex = num  // num is 1-9, maps to array index 1-9 (items 2-10)
                    if itemIndex < filteredItems.count {
                        let item = filteredItems[itemIndex]
                        
                        // Highlight the item before copying
                        self.highlightedItemId = item.id
                        
                        // Copy to clipboard first
                        self.viewModel.copyToPasteboard(item)
                        
                        // Wait a moment for clipboard to be ready, then hide and paste
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            // Hide popup and restore focus, then paste
                            HistoryPopupPresenter.shared.hideAndRestoreFocus {
                                // Paste to cursor position after focus is restored
                                self.pasteToCursor()
                            }
                        }
                        
                        // Clear highlight after brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            if self.highlightedItemId == item.id {
                                self.highlightedItemId = nil
                            }
                        }
                        
                        return nil  // Consume the event
                    } else {
                        self.logger.info("⚠️ [MenuBarContentView] Item index \(itemIndex) out of range (count: \(filteredItems.count))")
                    }
                }
            }
            return event
        }
        
        // Also add a global monitor as fallback (requires accessibility permissions)
        _ = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            // Only handle when history section is selected and popup is visible
            guard self.selectedSection == .history else { return }
            
            // Check for Alt+number (1-9)
            if event.modifierFlags.contains(.option) {
                let keyCode = event.keyCode
                let numberKeyCodes: [UInt16: Int] = [
                    18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
                    22: 6, 26: 7, 28: 8, 25: 9
                ]
                
                if let num = numberKeyCodes[keyCode] {
                    DispatchQueue.main.async {
                        self.logger.info("🎯 [MenuBarContentView] Alt+\(num) pressed (global monitor)")
                        
                        let filteredItems: [ClipboardEntry] = {
                            if self.search.trimmingCharacters(in: .whitespaces).isEmpty {
                                return self.viewModel.items
                            }
                            return self.viewModel.items.filter { $0.matches(query: self.search) }
                        }()
                        
                        let itemIndex = num
                        if itemIndex < filteredItems.count {
                            let item = filteredItems[itemIndex]
                            
                            // Highlight the item before copying
                            self.highlightedItemId = item.id
                            
                            // Copy to clipboard first
                            self.viewModel.copyToPasteboard(item)
                            
                            // Wait a moment for clipboard to be ready, then hide and paste
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                // Hide popup and restore focus, then paste
                                HistoryPopupPresenter.shared.hideAndRestoreFocus {
                                    // Paste to cursor position after focus is restored
                                    self.pasteToCursor()
                                }
                            }
                            
                            // Clear highlight after brief delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                if self.highlightedItemId == item.id {
                                    self.highlightedItemId = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func pasteToCursor() {
        // Use a delay to ensure clipboard is updated and focus is restored
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.logger.info("📋 Attempting to paste...")
            
            // Use global event tap - more reliable than postToPid
            guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true) else {
                self.logger.error("❌ Failed to create keyDown event")
                return
            }
            keyDownEvent.flags = .maskCommand
            
            // Post to HID event tap (this sends to the frontmost app)
            _ = keyDownEvent.post(tap: .cghidEventTap)
            self.logger.info("📋 KeyDown posted")
            
            // Small delay between key down and key up
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                guard let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
                    self.logger.error("❌ Failed to create keyUp event")
                    return
                }
                keyUpEvent.flags = .maskCommand
                _ = keyUpEvent.post(tap: .cghidEventTap)
                self.logger.info("✅ KeyUp posted")
            }
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
        
        logger.info("🔧 [MenuBarContentView] Setting up notification observers")
        
        // Set up observer for history section switch
        historySectionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowHistorySection"),
            object: nil,
            queue: .main
        ) { [self] _ in
            logger.info("📨 [MenuBarContentView] Received ShowHistorySection notification")
            // Switch to history section when shortcut is pressed
            selectedSection = .history
        }
        
        // Set up observer for showing popup - prevent duplicate calls
        historyPopupObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ShowHistoryPopup"),
            object: nil,
            queue: .main
        ) { [self] _ in
            guard !isHandlingPopup else { return }
            logger.info("📨 [MenuBarContentView] Received ShowHistoryPopup notification")
            
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
            logger.info("📨 [MenuBarContentView] Received ShowSettingsSection notification")
            // Switch to settings section
            selectedSection = .settings
        }
        
        logger.info("✅ [MenuBarContentView] Notification observers set up")
    }
    
    private func setupHighlightObserver() {
        // Set up observer for highlighting items when Alt+index is pressed
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("HighlightHistoryItem"),
            object: nil,
            queue: .main
        ) { notification in
            if let itemId = notification.userInfo?["itemId"] as? UUID {
                self.logger.info("✨ [MenuBarContentView] Highlighting item: \(itemId)")
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

    @ViewBuilder
    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                    // Only show shortcut for items 2-10 (index 1-9)
                    // Item 1 (index 0) doesn't need shortcut as it's already in clipboard
                    let shortcutIndex = index > 0 && index <= 9 ? index : nil
                    rowView(item: item, shortcutIndex: shortcutIndex)
                }
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
        .padding(8)
    }
}

private struct ClipboardCard: View {
    private let logger = HypoLogger(category: "ClipboardCard")
    let entry: ClipboardEntry
    let localDeviceId: String
    @State private var showFullContent = false
    
    private func openFileInFinder(entry: ClipboardEntry) {
        guard case .file(let fileMetadata) = entry.content else { return }
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
            logger.info("Failed to create temp file for Finder: \(error)")
        }
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
            return trimmed.count > 100
        case .link(let url):
            return url.absoluteString.count > 100
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
            return "Image · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
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
                                case .image, .text, .link:
                                    showFullContent = true
                                }
                            }) {
                                Image(systemName: {
                                    switch entry.content {
                                    case .file:
                                        return "folder"  // Folder icon for "Open in Finder"
                                    case .image, .text, .link:
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
                                case .image, .text, .link:
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
            logger.info("Failed to create temp file for Finder: \(error)")
        }
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
            return trimmed.count > 100
        case .link(let url):
            return url.absoluteString.count > 100
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
            return "Image · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
        case .file(let metadata):
            return "\(metadata.fileName) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                // Left column: Icon and keyboard shortcut index (only for items 2-10)
                VStack(alignment: .center, spacing: 4) {
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
                VStack(alignment: .leading, spacing: 2) {
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
                VStack(alignment: .trailing, spacing: 4) {
                    Text(entry.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button(action: { viewModel.togglePin(entry) }) {
                        Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.fill" : "pin")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(entry.isPinned ? .orange : .secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
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
                            case .image, .text, .link:
                                showFullContent = true
                            }
                        }) {
                            Image(systemName: {
                                switch entry.content {
                                case .file:
                                    return "folder"  // Folder icon for "Open in Finder"
                                case .image, .text, .link:
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
                            case .image, .text, .link:
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
        .padding(8)
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
            viewModel.copyToPasteboard(entry)
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
                    Toggle("Plain Text Mode (Debug)", isOn: Binding(
                        get: { viewModel.plainTextModeEnabled },
                        set: { viewModel.plainTextModeEnabled = $0 }
                    ))
                    Text("⚠️ Send clipboard without encryption. Less secure, for debugging only.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("History") {
                    Slider(value: Binding(
                        get: { Double(viewModel.historyLimit) },
                        set: { viewModel.updateHistoryLimit(Int($0)) }
                    ), in: 20...500, step: 10) {
                        Text("History size")
                    }
                    HStack {
                        Text("Current limit")
                        Spacer()
                        Text("\(viewModel.historyLimit)")
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

                Section("Security") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current encryption key")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(viewModel.encryptionKeySummary)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contextMenu {
                                Button("Copy") { viewModel.copyEncryptionKeyToPasteboard() }
                                Button("Regenerate", role: .destructive) { viewModel.regenerateEncryptionKey() }
                            }
                    }
                    HStack {
                        Button("Copy key") { viewModel.copyEncryptionKeyToPasteboard() }
                        Button("Regenerate key", role: .destructive) { viewModel.regenerateEncryptionKey() }
                    }
                }

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
                                Button(role: .destructive) {
                                    viewModel.removePairedDevice(device)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Remove device")
                            }
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
        // Get the app bundle - when running as .app, Bundle.main should be the app bundle
        let bundle = Bundle.main
        
        // Debug: log bundle info
        logger.info("📦 [SettingsSectionView] Bundle path: \(bundle.bundlePath)")
        logger.info("📦 [SettingsSectionView] Bundle identifier: \(bundle.bundleIdentifier ?? "nil")")
        logger.info("📦 [SettingsSectionView] Info dictionary keys: \(bundle.infoDictionary?.keys.sorted() ?? [])")
        
        if let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = bundle.infoDictionary?["CFBundleVersion"] as? String {
            logger.info("📦 [SettingsSectionView] Found version: \(version), build: \(build)")
            return "Version \(version) (Build \(build))"
        } else if let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
            logger.info("📦 [SettingsSectionView] Found version only: \(version)")
            return "Version \(version)"
        } else if let build = bundle.infoDictionary?["CFBundleVersion"] as? String {
            logger.info("📦 [SettingsSectionView] Found build only: \(build)")
            return "Build \(build)"
        } else {
            // Fallback: use Info.plist values directly
            logger.info("📦 [SettingsSectionView] No version found in bundle, using fallback")
            return "Version 1.0.0"
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
        case .idle:
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
        case .idle:
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
        case .idle:
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
        let hasLan = device.bonjourHost != nil && device.bonjourPort != nil && device.bonjourHost != "unknown"
        let isServerConnected = viewModel.connectionState == .connectedCloud
        
        // Get device transport to determine if it's using cloud (for cloud-only case)
        var deviceTransport: TransportChannel? = nil
        if let transportManager = viewModel.transportManager {
            deviceTransport = transportManager.lastSuccessfulTransport(for: device.id)
                ?? transportManager.lastSuccessfulTransport(for: device.name)
                ?? (device.serviceName != nil ? transportManager.lastSuccessfulTransport(for: device.serviceName!) : nil)
        }
        let isCloudTransport = deviceTransport == .cloud && isServerConnected
        
        // Match Android's logic: if device is discovered on LAN AND server is connected, show "and server"
        // This works even if the device doesn't have a cloud transport record yet
        if hasLan && isServerConnected {
            // Connected via both LAN and server (mirror Android's behavior)
            if let host = device.bonjourHost, let port = device.bonjourPort {
                return "Connected via \(host):\(port) and server"
            }
        } else if hasLan {
            // Connected via LAN only
            if let host = device.bonjourHost, let port = device.bonjourPort {
                return "Connected via \(host):\(port)"
            }
        } else if isCloudTransport {
            // Connected via cloud only (device has cloud transport record)
            return "Connected via server"
        }
        
        // Fallback: just show "Connected" if online but no specific connection info
        return "Connected"
    }
}

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
        case .idle:
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
        case .idle:
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
        case .idle:
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
                            // No image data available
                            Text("Image · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))")
                                .padding()
                        }
                        
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

// File detail view with save functionality
private struct FileDetailView: View {
    let metadata: FileMetadata
    @State private var isSaving = false
    @State private var saveError: String?
    
    private var isTextFile: Bool {
        let fileName = metadata.fileName.lowercased()
        let textExtensions = ["txt", "md", "json", "xml", "html", "css", "js", "py", "swift", "kt", "java", "c", "cpp", "h", "hpp", "sh", "yaml", "yml", "log", "csv"]
        return textExtensions.contains { fileName.hasSuffix(".\($0)") }
    }
    
    private var fileData: Data? {
        guard let base64 = metadata.base64 else { return nil }
        return Data(base64Encoded: base64)
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
            
            // Content display
            if let content = fileContent, isTextFile {
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
                Text("Unable to decode file data")
                    .foregroundStyle(.secondary)
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


#endif
