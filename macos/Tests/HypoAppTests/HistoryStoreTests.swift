import XCTest
@testable import HypoApp

final class HistoryStoreTests: XCTestCase {
    func testInsertDeDuplicatesEntriesByContent() async {
        let store = HistoryStore(maxEntries: 10)
        let textEntry = ClipboardEntry(originDeviceId: "macos", content: .text("Hello"))
        _ = await store.insert(textEntry)
        _ = await store.insert(textEntry)

        let items = await store.all()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.content, .text("Hello"))
    }

    func testInsertCapsByMaxEntries() async {
        let store = HistoryStore(maxEntries: 3)
        for index in 0..<5 {
            let entry = ClipboardEntry(originDeviceId: "macos", content: .text("Item \(index)"))
            _ = await store.insert(entry)
        }

        let items = await store.all()
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.content, .text("Item 4"))
        XCTAssertEqual(items.last?.content, .text("Item 2"))
    }

    func testEntryLookupByIdentifierReturnsMatchingEntry() async {
        let store = HistoryStore(maxEntries: 5)
        let expected = ClipboardEntry(originDeviceId: "macos", content: .text("Lookup"))
        _ = await store.insert(expected)

        let result = await store.entry(withID: expected.id)

        XCTAssertEqual(result?.id, expected.id)
        XCTAssertEqual(result?.content, expected.content)
    }
}
