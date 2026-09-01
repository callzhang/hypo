import Foundation
import Testing
import HypoCore
@testable import HypoiOS

@Suite("HistoryListViewModel")
struct HistoryListViewModelTests {
    private func makeEntry(_ text: String, deviceId: String = "test-device") -> ClipboardEntry {
        ClipboardEntry(
            deviceId: deviceId,
            originDeviceName: "Test",
            content: .text(text),
            transportOrigin: .lan
        )
    }

    @Test("loading reflects what the store holds")
    @MainActor
    func loadsFromStore() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        _ = await store.insert(makeEntry("first"))
        let viewModel = HistoryListViewModel(store: store)

        await viewModel.load()

        #expect(viewModel.entries.count == 1)
    }

    @Test("search filters by content")
    @MainActor
    func searchFilters() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        _ = await store.insert(makeEntry("alpha"))
        _ = await store.insert(makeEntry("beta"))
        let viewModel = HistoryListViewModel(store: store)
        await viewModel.load()

        viewModel.searchText = "alph"

        #expect(viewModel.visibleEntries.count == 1)
    }

    @Test("search reaches past the length the preview truncates at")
    @MainActor
    func searchLooksBeyondThePreview() async {
        // previewDescription cuts text off at 100 characters, so filtering on
        // it would never find this needle. matches(query:) searches the whole
        // string, the way the macOS list does.
        let long = String(repeating: "x", count: 200) + "needle"
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        _ = await store.insert(makeEntry(long))
        let viewModel = HistoryListViewModel(store: store)
        await viewModel.load()

        viewModel.searchText = "needle"

        #expect(viewModel.visibleEntries.count == 1)
    }

    @Test("an empty query shows everything")
    @MainActor
    func emptyQueryShowsAll() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        _ = await store.insert(makeEntry("one"))
        _ = await store.insert(makeEntry("two"))
        let viewModel = HistoryListViewModel(store: store)
        await viewModel.load()

        viewModel.searchText = ""

        #expect(viewModel.visibleEntries.count == 2)
    }

    @Test("an incoming remote entry lands in the list")
    @MainActor
    func remoteEntryArrives() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        let viewModel = HistoryListViewModel(store: store)
        let entry = makeEntry("from mac")
        _ = await store.insert(entry)

        await viewModel.handleIncomingRemoteEntry(entry, duplicate: nil)

        #expect(viewModel.entries.contains { $0.id == entry.id })
    }

    @Test("removing an entry drops it from the list")
    @MainActor
    func removeDropsEntry() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        let entry = makeEntry("doomed")
        _ = await store.insert(entry)
        let viewModel = HistoryListViewModel(store: store)
        await viewModel.load()

        await viewModel.remove(id: entry.id)

        #expect(viewModel.entries.isEmpty)
    }

    @Test("clearing empties the list")
    @MainActor
    func clearEmptiesList() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        _ = await store.insert(makeEntry("a"))
        _ = await store.insert(makeEntry("b"))
        let viewModel = HistoryListViewModel(store: store)
        await viewModel.load()

        await viewModel.clearAll()

        #expect(viewModel.entries.isEmpty)
    }
}
