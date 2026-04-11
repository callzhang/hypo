import Foundation
import Testing
@testable import HypoApp

struct HistoryStoreTests {
    @Test
    @MainActor
    func testLocalClipboardInsertDoesNotDeliverNotification() async {
        let store = makeStore(maxEntries: 10)
        let notificationController = MockNotificationController()
        let deviceIdentity = TestDeviceIdentity(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let viewModel = ClipboardHistoryViewModel(
            store: store,
            defaults: makeDefaults(suiteName: "HistoryStoreTests.LocalNotification.\(UUID().uuidString)"),
            deviceIdentity: deviceIdentity,
            notificationController: notificationController
        )

        let entry = ClipboardEntry(
            deviceId: deviceIdentity.deviceIdString,
            originPlatform: .macOS,
            originDeviceName: "Test Mac",
            content: .text("Local copy")
        )

        await viewModel.add(entry)

        #expect(notificationController.deliveredEntries.isEmpty)
    }

    @Test
    @MainActor
    func testRemoteEchoOfLocalClipboardDoesNotDeliverNotification() async {
        let store = makeStore(maxEntries: 10)
        let notificationController = MockNotificationController()
        let deviceIdentity = TestDeviceIdentity(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let viewModel = ClipboardHistoryViewModel(
            store: store,
            defaults: makeDefaults(suiteName: "HistoryStoreTests.RemoteEcho.\(UUID().uuidString)"),
            deviceIdentity: deviceIdentity,
            notificationController: notificationController
        )

        let localEntry = ClipboardEntry(
            deviceId: deviceIdentity.deviceIdString,
            originPlatform: .macOS,
            originDeviceName: "Test Mac",
            content: .text("Echo me")
        )
        await viewModel.add(localEntry)

        let remoteEcho = ClipboardEntry(
            deviceId: "android-device",
            originPlatform: .Android,
            originDeviceName: "Pixel",
            content: .text("Echo me")
        )
        await viewModel.add(remoteEcho)

        #expect(notificationController.deliveredEntries.isEmpty)
    }

    @Test
    @MainActor
    func testRemoteClipboardInsertStillDeliversNotification() async {
        let store = makeStore(maxEntries: 10)
        let notificationController = MockNotificationController()
        let deviceIdentity = TestDeviceIdentity(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let viewModel = ClipboardHistoryViewModel(
            store: store,
            defaults: makeDefaults(suiteName: "HistoryStoreTests.RemoteNotification.\(UUID().uuidString)"),
            deviceIdentity: deviceIdentity,
            notificationController: notificationController
        )

        let remoteEntry = ClipboardEntry(
            deviceId: "android-device",
            originPlatform: .Android,
            originDeviceName: "Pixel",
            content: .text("Remote copy")
        )

        await viewModel.add(remoteEntry)

        #expect(notificationController.deliveredEntries.map(\.id) == [remoteEntry.id])
    }

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
    let defaults = makeDefaults(suiteName: "HistoryStoreTests.\(UUID().uuidString)")
    return HistoryStore(maxEntries: maxEntries, defaults: defaults)
}

private func makeDefaults(suiteName: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: "com.hypo.clipboard.file_storage_migration_v2")
    return defaults
}

private struct TestDeviceIdentity: DeviceIdentityProviding {
    let deviceId: UUID
    let platform: DevicePlatform = .macOS
    let deviceName: String = "Test Mac"

    var deviceIdString: String {
        deviceId.uuidString.lowercased()
    }

    init(id: UUID) {
        self.deviceId = id
    }
}
