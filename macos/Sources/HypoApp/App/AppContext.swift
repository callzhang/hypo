import Foundation

/// Shared app-scoped references needed outside SwiftUI view lifecycles.
final class AppContext {
    static let shared = AppContext()
    private init() {}

    /// Current history view model (set during app init).
    weak var historyViewModel: ClipboardHistoryViewModel?
}
