import Foundation
import Testing
import HypoCore
@testable import HypoiOS

@Suite("Send path")
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
}
