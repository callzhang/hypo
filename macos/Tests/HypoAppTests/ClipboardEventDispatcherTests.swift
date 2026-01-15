import Testing
import Foundation
@testable import HypoApp

@MainActor
struct ClipboardEventDispatcherTests {
    @Test
    func testDispatchNotifiesAllObservers() {
        let dispatcher = ClipboardEventDispatcher()
        var callCount1 = 0
        var callCount2 = 0
        
        dispatcher.addClipboardAppliedHandler { _ in callCount1 += 1 }
        dispatcher.addClipboardAppliedHandler { _ in callCount2 += 1 }
        
        dispatcher.notifyClipboardApplied(changeCount: 10)
        
        #expect(callCount1 == 1)
        #expect(callCount2 == 1)
    }
    
    @Test
    func testDispatchReceivedNotifiesAllObservers() {
        let dispatcher = ClipboardEventDispatcher()
        var receivedId: String?
        
        dispatcher.addClipboardReceivedHandler { id, _ in receivedId = id }
        
        dispatcher.notifyClipboardReceived(deviceId: "test-device", timestamp: Date())
        
        #expect(receivedId == "test-device")
    }
}
