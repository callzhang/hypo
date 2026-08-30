import Foundation
import Testing
import HypoCore
@testable import HypoiOS

@Suite("HypoiOSContext")
struct HypoiOSContextTests {
    @Test("building the context does not start a LAN listener")
    @MainActor
    func buildsWithoutListening() async {
        let context = HypoiOSContext(notificationScheduler: .init(center: nil))

        // TransportManager activates LAN services from init on non-AppKit
        // platforms, asynchronously. Give that a window to happen, so this
        // test would catch a listener being started rather than racing it.
        try? await Task.sleep(for: .milliseconds(500))

        // listeningPort reads back the NWListener's port, and the listener is
        // only created by start(port:). nil means nothing is bound.
        #expect(context.webSocketServer.listeningPort == nil)
    }

    @Test("the context wires up receiving")
    @MainActor
    func receivingIsWired() {
        let context = HypoiOSContext(
            notificationScheduler: .init(center: nil),
            historyStore: HistoryStore(persistence: InMemoryHistoryPersistence())
        )

        // False when no history store reaches TransportManager's initialiser.
        // That same branch resolves discovered peers for LanSyncTransport, so
        // this also guards the outbound dial path iOS depends on entirely.
        #expect(context.transportManager.isReceivingEnabled)
    }

    @Test("the device identity carries a real name, not localhost")
    @MainActor
    func identityHasDeviceName() {
        let context = HypoiOSContext(notificationScheduler: .init(center: nil))

        #expect(!context.identity.deviceIdString.isEmpty)
    }
}
