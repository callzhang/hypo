import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Shared app-scoped references needed outside SwiftUI view lifecycles.
@MainActor
final class AppContext {
    static let shared = AppContext()
    nonisolated private init() {}

    /// Current history view model (set during app init).
    var historyViewModel: ClipboardHistoryViewModel?
    
    /// Shared TransportManager instance
    var transportManager: TransportManager?
    
    /// Shared HistoryStore instance
    var historyStore: HistoryStore?
    /// Shared SecurityManager instance
    var securityManager: SecurityManager?
    
    #if canImport(AppKit)
    /// Single clipboard monitor instance shared across app lifecycle to avoid double-captures.
    var clipboardMonitor: ClipboardMonitor?
    #endif

    /// Blocks the Show Clipboard hotkey while the settings recorder is capturing a new shortcut.
    var isRecordingShowClipboardShortcut = false

    /// Current Carbon event id for the active Show Clipboard shortcut registration.
    var activeShowClipboardHotKeyID: UInt32 = 0
}
