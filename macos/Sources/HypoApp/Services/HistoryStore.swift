import Foundation

#if canImport(Combine)
import Combine
#endif

public actor HistoryStore {
    private var entries: [ClipboardEntry] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
    }

    @discardableResult
    public func insert(_ entry: ClipboardEntry) -> [ClipboardEntry] {
        if let index = entries.firstIndex(where: { $0.content == entry.content }) {
            entries.remove(at: index)
        }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        return entries
    }

    public func all() -> [ClipboardEntry] {
        entries
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public func clear() {
        entries.removeAll()
    }
}

#if canImport(SwiftUI)
import SwiftUI
#endif

@MainActor
public final class ClipboardHistoryViewModel: ObservableObject {
    @Published public private(set) var items: [ClipboardEntry] = []
    private let store: HistoryStore
    private var loadTask: Task<Void, Never>?

    public init(store: HistoryStore = HistoryStore()) {
        self.store = store
    }

    deinit {
        loadTask?.cancel()
    }

    public func start() async {
        loadTask?.cancel()
        loadTask = Task { [store] in
            let snapshot = await store.all()
            await MainActor.run { self.items = snapshot }
        }
    }

    public func add(_ entry: ClipboardEntry) async {
        let updated = await store.insert(entry)
        await MainActor.run { self.items = updated }
    }

    public func remove(id: UUID) async {
        await store.remove(id: id)
        await MainActor.run { self.items.removeAll { $0.id == id } }
    }

    public func clearHistory() {
        Task {
            await store.clear()
            await MainActor.run { self.items.removeAll() }
        }
    }
}
