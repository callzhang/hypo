import Foundation
import Testing
@testable import HypoApp

struct HistoryStoreTests {
    @Test
    func testInsertDeDuplicatesEntriesByContent() async {
        let store = makeStore(maxEntries: 10)
        let textEntry = ClipboardEntry(
            deviceId: "macos",
            originPlatform: .macOS,
            originDeviceName: "Test Mac",
            content: .text("Hello")
        )
        _ = await store.insert(textEntry)
        _ = await store.insert(textEntry)

        let items = await store.all()
        #expect(items.count == 1)
        #expect(items.first?.content == .text("Hello"))
    }

    @Test
    func testInsertCapsByMaxEntries() async {
        let store = makeStore(maxEntries: 3)
        for index in 0..<5 {
            let entry = ClipboardEntry(
                deviceId: "macos",
                originPlatform: .macOS,
                originDeviceName: "Test Mac",
                content: .text("Item \(index)")
            )
            _ = await store.insert(entry)
        }

        let items = await store.all()
        #expect(items.count == 3)
        #expect(items.first?.content == .text("Item 4"))
        #expect(items.last?.content == .text("Item 2"))
    }

    @Test
    func testEntryLookupByIdentifierReturnsMatchingEntry() async {
        let store = makeStore(maxEntries: 5)
        let expected = ClipboardEntry(
            deviceId: "macos",
            originPlatform: .macOS,
            originDeviceName: "Test Mac",
            content: .text("Lookup")
        )
        _ = await store.insert(expected)

        let result = await store.entry(withID: expected.id)

        #expect(result?.id == expected.id)
        #expect(result?.content == expected.content)
    }
}

private func makeStore(maxEntries: Int) -> HistoryStore {
    let suiteName = "HistoryStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return HistoryStore(maxEntries: maxEntries, defaults: defaults)
}
