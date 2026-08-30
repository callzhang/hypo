import Foundation
import Combine
import HypoCore

/// Backs the history list and receives entries arriving from paired devices.
@MainActor
public final class HistoryListViewModel: ObservableObject, RemoteEntryReceiving {
    @Published public private(set) var entries: [ClipboardEntry] = []
    @Published public var searchText: String = ""

    private let store: HistoryStore

    public init(store: HistoryStore) {
        self.store = store
    }

    /// Filtered through `ClipboardEntry.matches(query:)`, the same predicate the
    /// macOS list uses, so search behaves identically on both platforms. It
    /// looks at the device id and the full text, link, image alt text or file
    /// name — where filtering on `content.previewDescription` would miss any
    /// match past the 100 characters that preview truncates at, and would match
    /// images against a formatted "name · PNG · 1.2 MB" string rather than
    /// their alt text.
    public var visibleEntries: [ClipboardEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.matches(query: searchText) }
    }

    public func load() async {
        entries = await store.all()
    }

    public func handleIncomingRemoteEntry(_ entry: ClipboardEntry, duplicate: ClipboardEntry?) async {
        entries = await store.all()
    }

    public func remove(id: UUID) async {
        await store.remove(id: id)
        entries = await store.all()
    }

    public func togglePin(id: UUID) async {
        entries = await store.togglePin(id: id)
    }

    public func clearAll() async {
        await store.clear()
        entries = await store.all()
    }
}
