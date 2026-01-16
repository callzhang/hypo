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

    @Test
    func testEntriesPersistAcrossInstances() async {
        let suiteName = "HistoryStoreTests.Persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        
        // 1. Create store and insert entry
        let entry = ClipboardEntry(
            deviceId: "macos",
            originPlatform: .macOS,
            originDeviceName: "Test Mac",
            content: .text("Persisted")
        )
        
        let store1 = HistoryStore(maxEntries: 10, defaults: defaults)
        _ = await store1.insert(entry)
        
        // 2. Create new store instance with same defaults
        let store2 = HistoryStore(maxEntries: 10, defaults: defaults)
        let items = await store2.all()
        
        // 3. Verify entry was loaded
        #expect(items.count == 1)
        #expect(items.first?.content == .text("Persisted"))
    }
    
    @Test
    func testRemoveEntry() async {
        let store = makeStore(maxEntries: 5)
        let entry = ClipboardEntry(
            deviceId: "macos",
            originPlatform: .macOS,
            originDeviceName: "Test Mac",
            content: .text("To Delete")
        )
        _ = await store.insert(entry)
        
        let itemsAfterInsert = await store.all()
        #expect(itemsAfterInsert.count == 1)
        
        await store.remove(id: entry.id)
        
        let itemsAfterDelete = await store.all()
        #expect(itemsAfterDelete.isEmpty)
    }
    
    @Test
    func testClearAllEntries() async {
        let store = makeStore(maxEntries: 5)
        for i in 0..<3 {
            let entry = ClipboardEntry(
                deviceId: "macos",
                originPlatform: .macOS,
                originDeviceName: "Test Mac",
                content: .text("Item \(i)")
            )
            _ = await store.insert(entry)
        }
        
        #expect(await store.all().count == 3)
        
        await store.clear()
        
        #expect(await store.all().isEmpty)
    }
    
    @Test
    func testReinsertingExistingEntryMovesItToTop() async {
        let store = makeStore(maxEntries: 5)
        let entry1 = ClipboardEntry(
            timestamp: Date(timeIntervalSince1970: 1),
            deviceId: "d1",
            originPlatform: .macOS,
            originDeviceName: "Mac",
            content: .text("First")
        )
        let entry2 = ClipboardEntry(
            timestamp: Date(timeIntervalSince1970: 2),
            deviceId: "d1",
            originPlatform: .macOS,
            originDeviceName: "Mac",
            content: .text("Second")
        )
        
        _ = await store.insert(entry1)
        _ = await store.insert(entry2)
        
        var items = await store.all()
        #expect(items.count == 2)
        #expect(items.first?.id == entry2.id) // Recent on top
        
        // Re-insert entry1 (content match)
        let entry1Duplicate = ClipboardEntry(
            deviceId: "d2", // Different device, but same content
            originPlatform: .Android,
            originDeviceName: "Phone",
            content: .text("First")
        )
        _ = await store.insert(entry1Duplicate)
        
        items = await store.all()
        #expect(items.count == 2) // No new item
        #expect(items.first?.content == .text("First")) // entry1 moved to top
    }
}

private func makeStore(maxEntries: Int) -> HistoryStore {
    let suiteName = "HistoryStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return HistoryStore(maxEntries: maxEntries, defaults: defaults)
}
