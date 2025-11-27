import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Shared app-scoped references needed outside SwiftUI view lifecycles.
final class AppContext {
    static let shared = AppContext()
    private init() {}

    /// Current history view model (set during app init).
    weak var historyViewModel: ClipboardHistoryViewModel?
    
    #if canImport(AppKit)
    /// Single clipboard monitor instance shared across app lifecycle to avoid double-captures.
    var clipboardMonitor: ClipboardMonitor?
    #endif
}
