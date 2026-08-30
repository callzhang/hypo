import Testing
import Foundation
import CryptoKit
import Network
@testable import HypoCore

/// A clipboard entry travelling from one device to another over a real LAN
/// socket, encrypted, and landing in the receiver's history.
///
/// Everything here is the production path: LanWebSocketServer binds a real
/// port, LanWebSocketTransport dials it, SyncEngine seals the envelope and
/// IncomingClipboardHandler opens it and writes to a HistoryStore. Only the
/// two ends being in one process is artificial.
///
/// This is the shape of what iOS does when it dials a Mac: iOS is a LAN client
/// only, so it is always the side making the connection.
@Suite("LAN clipboard sync", .serialized)
@MainActor
struct LanClipboardSyncTests {
    @Test("an entry sent over LAN lands in the receiver's history", .timeLimit(.minutes(1)))
    func entryCrossesTheWire() async throws {
        let senderId = UUID().uuidString.lowercased()
        let receiverId = UUID().uuidString.lowercased()

        // One key, as pairing would have left on both devices.
        let sharedKey = SymmetricKey(size: .bits256)
        let keyProvider = InMemoryDeviceKeyProvider()
        await keyProvider.setKey(sharedKey, for: senderId)
        await keyProvider.setKey(sharedKey, for: receiverId)

        // Receiving side: a real listener, and the handler the app uses.
        let server = LanWebSocketServer(localDeviceId: receiverId)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort(timeout: 5.0)

        let historyStore = HistoryStore(persistence: InMemoryHistoryPersistence())
        let clipboard = RecordingClipboard()
        let receiverEngine = SyncEngine(
            transport: InertTransport(),
            keyProvider: keyProvider,
            localDeviceId: receiverId
        )
        let handler = IncomingClipboardHandler(
            syncEngine: receiverEngine,
            historyStore: historyStore,
            dispatcher: ClipboardEventDispatcher(),
            clipboard: clipboard
        )
        // The server hands inbound frames to its delegate; that is where the
        // app plugs the incoming handler in.
        let inbox = ClipboardInbox(handler: handler)
        server.delegate = inbox

        // Sending side dials the listener, the way iOS dials a Mac. Uses a
        // plain web socket rather than LanWebSocketTransport so the test stays
        // about the sync path — envelope, framing, crypto, handler — and does
        // not depend on that wrapper's own connection handshake.
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: URL(string: "ws://localhost:\(port)")!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let transport = WebSocketFrameTransport(socket: socket)

        let senderEngine = SyncEngine(
            transport: transport,
            keyProvider: keyProvider,
            localDeviceId: senderId
        )
        await senderEngine.establishConnection()

        let entry = ClipboardEntry(
            deviceId: senderId,
            originPlatform: .iOS,
            originDeviceName: "iPhone",
            content: .text("hello from the phone"),
            transportOrigin: .lan
        )
        try await senderEngine.transmit(
            entry: entry,
            payload: ClipboardPayload(contentType: .text, data: Data("hello from the phone".utf8)),
            targetDeviceId: receiverId
        )

        let arrived = await waitUntil(timeout: .seconds(10)) {
            await historyStore.all().contains { entry in
                if case .text(let text) = entry.content { return text == "hello from the phone" }
                return false
            }
        }
        #expect(arrived, "the entry never reached the receiver's history")

        // And it was applied to the receiving device's clipboard, which is the
        // part the user actually notices.
        #expect(clipboard.textToReturn == "hello from the phone")
    }
}

/// Stands in for the transport on the receiving side, which never sends.
private final class InertTransport: SyncTransport {
    func connect() async throws {}
    func send(_ envelope: SyncEnvelope) async throws {}
    func disconnect() async {}
}

/// Writes envelopes onto a web socket using the wire framing the server reads.
private final class WebSocketFrameTransport: SyncTransport {
    private let socket: URLSessionWebSocketTask
    private let codec = TransportFrameCodec()

    init(socket: URLSessionWebSocketTask) { self.socket = socket }

    func connect() async throws {}
    func disconnect() async {}

    func send(_ envelope: SyncEnvelope) async throws {
        try await socket.send(.data(try codec.encode(envelope)))
    }
}

/// Routes frames off the wire into the incoming handler, the way
/// TransportManager does.
private final class ClipboardInbox: LanWebSocketServerDelegate, @unchecked Sendable {
    private let handler: IncomingClipboardHandler

    init(handler: IncomingClipboardHandler) { self.handler = handler }


    func server(_ server: LanWebSocketServer, didReceivePairingChallenge challenge: PairingChallengeMessage, from connection: UUID) {}
    func server(_ server: LanWebSocketServer, didAcceptConnection id: UUID) {}
    func server(_ server: LanWebSocketServer, didCloseConnection id: UUID) {}

    func server(_ server: LanWebSocketServer, didReceiveClipboardData data: Data, from connection: UUID) {
        Task { @MainActor in await handler.handle(data) }
    }
}
