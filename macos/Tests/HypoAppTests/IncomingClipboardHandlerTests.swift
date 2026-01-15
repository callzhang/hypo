import Testing
import Foundation
import AppKit
import CryptoKit
@testable import HypoApp

@MainActor
struct IncomingClipboardHandlerTests {
    @Test
    func testHandleIncomingDecodesAndAppliesClipboard() async throws {
        // Setup Dependencies
        // Setup Dependencies
        let historyStore = HistoryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let dispatcher = ClipboardEventDispatcher()
        let keyProvider = InMemoryDeviceKeyProvider()
        let transport = NoopTransport()
        let syncEngine = SyncEngine(transport: transport, keyProvider: keyProvider, localDeviceId: "mac")
        
        let pasteboard = NSPasteboard.withUniqueName()
        
        let handler = IncomingClipboardHandler(
            syncEngine: syncEngine,
            historyStore: historyStore,
            dispatcher: dispatcher,
            pasteboard: pasteboard
        )
        
        // Setup Key
        let sharedKey = SymmetricKey(size: .bits256)
        await keyProvider.setKey(sharedKey, for: "sender")
        
        // Create Payload
        let payload = ClipboardPayload(contentType: .text, data: Data("Hello Test".utf8))
        let entry = ClipboardEntry(
             deviceId: "sender", 
             originPlatform: .Android, 
             originDeviceName: "Phone", 
             content: .text("Hello Test")
        )
        
        // To get valid frame: use another SyncEngine acting as sender
        // Receiver expects key for "sender". Sender needs key for "mac" (the test device).
        // Since we reuse InMemoryKeyProvider logic, we can just set both keys.
        await keyProvider.setKey(sharedKey, for: "mac") // sender encrypts for "mac"
        
        // Use a transport that captures the sent envelope
        let recordingTransport = RecordingTransport()
        let senderEngine = SyncEngine(
             transport: recordingTransport,
             keyProvider: keyProvider,
             localDeviceId: "sender"
        )
        await senderEngine.establishConnection()
        try await senderEngine.transmit(entry: entry, payload: payload, targetDeviceId: "mac")
        
        let sentEnvelope = try #require(recordingTransport.sentEnvelopes.first)
        let frameData = try TransportFrameCodec().encode(sentEnvelope)
        
        // Execution
        var receivedParams: (String, Date)?
        dispatcher.addClipboardReceivedHandler { id, date in receivedParams = (id, date) }
        
        await handler.handle(frameData)
        
        // Verify Pasteboard
        #expect(pasteboard.string(forType: .string) == "Hello Test")
        
        // Verify History
        let recent = await historyStore.all()
        #expect(recent.count >= 1)
        
        let firstEntry = recent.first
        #expect(firstEntry != nil)
        
        if case .text(let text) = firstEntry?.content {
            #expect(text == "Hello Test")
        } else {
            Issue.record("Expected text content")
        }
        #expect(recent.first?.deviceId == "sender")
        
        // Verify Dispatcher
        #expect(receivedParams?.0 == "sender")
    }
}

// Helpers
private final class InMemoryDeviceKeyProvider: DeviceKeyProviding, @unchecked Sendable {
    private var keys: [String: SymmetricKey] = [:]
    
    func key(for deviceId: String) async throws -> SymmetricKey {
        guard let key = keys[deviceId] else {
            throw DeviceKeyProviderError.missingKey(deviceId)
        }
        return key
    }
    
    func setKey(_ key: SymmetricKey, for deviceId: String) async {
        keys[deviceId] = key
    }
}

private final class RecordingTransport: SyncTransport, @unchecked Sendable {
    private(set) var sentEnvelopes: [SyncEnvelope] = []
    
    func connect() async throws {}
    func send(_ envelope: SyncEnvelope) async throws {
        sentEnvelopes.append(envelope)
    }
    func disconnect() async {}
}

private struct NoopTransport: SyncTransport {
    func connect() async throws {}
    func send(_ envelope: SyncEnvelope) async throws {}
    func disconnect() async {}
}
