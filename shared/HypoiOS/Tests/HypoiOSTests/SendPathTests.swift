import Foundation
import Testing
import HypoCore
@testable import HypoiOS

// Serialized: paired devices are persisted process-wide, so a test that
// registers one runs concurrently with the test that expects none and makes it
// fail depending on which wins. It did.
@Suite("Send path", .serialized)
struct SendPathTests {
    @Test("sending with nothing attached reports notConfigured and stores nothing")
    @MainActor
    func sendWithoutTransportIsSafe() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        let viewModel = HistoryListViewModel(store: store)

        let outcome = await viewModel.sendText("no transport attached")

        #expect(outcome == .notConfigured)
        #expect(viewModel.lastSendOutcome == .notConfigured)
        #expect(viewModel.entries.isEmpty)
    }

    @Test("sending with no paired devices says so rather than looking successful")
    @MainActor
    func sendWithoutPairedDevices() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        let context = HypoiOSContext(
            notificationScheduler: .init(center: nil),
            historyStore: store
        )

        let outcome = await context.historyViewModel.sendText("nobody to send to")

        // The entry would still be recorded locally on any other outcome, so
        // without this distinction a send that reached nobody is invisible.
        #expect(outcome == .noPairedDevices)
        #expect(context.historyViewModel.entries.isEmpty)
    }

    @Test("what this device sends lands in its own history, and reads as its own")
    @MainActor
    func sentTextIsRecordedLocally() async {
        let store = HistoryStore(persistence: InMemoryHistoryPersistence())
        let context = HypoiOSContext(
            notificationScheduler: .init(center: nil),
            historyStore: store
        )
        // Paired devices are persisted process-wide, so leaving this one
        // registered makes the sibling test that expects none fail depending on
        // the order they run in. It did.
        let peer = PairedDevice(
            id: "unreachable-\(UUID().uuidString)",
            name: "Nowhere",
            platform: "android",
            lastSeen: Date(),
            isOnline: false,
            serviceName: nil,
            bonjourHost: nil,
            bonjourPort: nil,
            fingerprint: nil
        )
        // Leftovers from an earlier run persist too, so clear them first.
        for stale in context.transportManager.pairedDevices where stale.name == "Nowhere" {
            context.unpair(stale)
        }
        context.transportManager.registerPairedDevice(peer)
        defer { context.unpair(peer) }

        let text = "recorded locally \(UUID().uuidString.prefix(8))"
        _ = await context.historyViewModel.sendText(text)

        // Reaching nobody is fine; losing the user's own clipboard is not.
        // The entry used to be stored only after awaiting delivery to every
        // paired device, so one unreachable peer kept it out of this device's
        // own history for as long as that peer hung.
        let entry = context.historyViewModel.entries.first { $0.previewText.contains(text) }
        #expect(entry != nil, "text this device sent is missing from its own history")

        // Nil origin is what HistoryStore and the row treat as "ours"; a
        // transport origin renders it as though it arrived from elsewhere.
        #expect(entry?.transportOrigin == nil)
    }
}
