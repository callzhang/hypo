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

@Suite("LAN send failure reporting")
@MainActor
struct LanSendFailureTests {
    @Test("sending to a device with no connection throws rather than claiming success")
    func unreachableTargetThrows() async throws {
        let server = LanWebSocketServer(localDeviceId: "local-device")
        try server.start(port: 0)
        defer { server.stop() }
        _ = try await server.waitForPort(timeout: 5.0)

        let transport = LanSyncTransport(server: server)
        try await transport.connect()

        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: SyncEnvelope.Payload(
                contentType: .text,
                ciphertext: Data("nobody is listening".utf8),
                deviceId: "local-device",
                devicePlatform: "test",
                deviceName: "Local",
                target: "a-device-that-is-not-connected",
                encryption: SyncEnvelope.EncryptionMetadata(
                    nonce: Data(repeating: 0, count: 12),
                    tag: Data(repeating: 0, count: 16)
                )
            )
        )

        // Used to return normally, so callers reported "sent" for items that
        // went nowhere — the reason iOS said "Sent to 1 device" with no
        // connection open.
        await #expect(throws: LanSyncTransportError.self) {
            try await transport.send(envelope)
        }
    }
}

@Suite("LAN dial URL")
struct LanDialURLTests {
    /// The URL a LAN dial actually uses, after the transport strips the query.
    private func cleanedLanURL(from original: URL) throws -> URL {
        var components = URLComponents(url: original, resolvingAgainstBaseURL: false)
        components?.query = nil
        if components?.path.isEmpty ?? true { components?.path = "/ws" }
        return try #require(components?.url)
    }

    @Test("the port survives")
    func keepsPort() throws {
        // Rebuilding the URL as scheme://host+path dropped the port, so every
        // dial to a peer on 7010 went to 80 and could never connect.
        let url = try cleanedLanURL(from: URL(string: "ws://10.0.0.252:7010")!)
        #expect(url.port == 7010)
        #expect(url.host == "10.0.0.252")
        #expect(url.path == "/ws")
    }

    @Test("the query goes, everything else stays")
    func dropsOnlyQuery() throws {
        let url = try cleanedLanURL(from: URL(string: "ws://10.0.0.252:7010/socket?token=abc")!)
        #expect(url.query == nil)
        #expect(url.port == 7010)
        #expect(url.path == "/socket")
    }
}

@Suite("Arriving before the key does")
@MainActor
struct LateKeyDeliveryTests {
    @Test("an entry that arrives while pairing is still settling is not lost", .timeLimit(.minutes(1)))
    func waitsForTheKey() async throws {
        let senderId = UUID().uuidString.lowercased()
        let receiverId = UUID().uuidString.lowercased()
        let sharedKey = SymmetricKey(size: .bits256)

        let keyProvider = InMemoryDeviceKeyProvider()
        // Deliberately not registered yet: this is the moment after the peer
        // has answered the pairing challenge and before this side has finished
        // writing the key it derived.
        await keyProvider.setKey(sharedKey, for: receiverId)

        let senderProvider = InMemoryDeviceKeyProvider()
        await senderProvider.setKey(sharedKey, for: senderId)
        await senderProvider.setKey(sharedKey, for: receiverId)

        let recording = CapturingTransport()
        let sender = SyncEngine(
            transport: recording,
            keyProvider: senderProvider,
            localDeviceId: senderId
        )
        await sender.establishConnection()
        try await sender.transmit(
            entry: ClipboardEntry(deviceId: senderId, content: .text("arrived early")),
            payload: ClipboardPayload(contentType: .text, data: Data("arrived early".utf8)),
            targetDeviceId: receiverId
        )
        let frame = try TransportFrameCodec().encode(try #require(await recording.sent.first))

        let historyStore = HistoryStore(persistence: InMemoryHistoryPersistence())
        let handler = IncomingClipboardHandler(
            syncEngine: SyncEngine(
                transport: InertTransport(),
                keyProvider: keyProvider,
                localDeviceId: receiverId
            ),
            historyStore: historyStore,
            dispatcher: ClipboardEventDispatcher(),
            clipboard: RecordingClipboard()
        )

        // Hand it the frame first, register the key a moment later — the order
        // a peer that sends the instant it is paired produces.
        async let handled: Void = handler.handle(frame)
        try await Task.sleep(for: .milliseconds(1500))
        await keyProvider.setKey(sharedKey, for: senderId)
        await handled

        let arrived = await waitUntil(timeout: .seconds(10)) {
            await historyStore.all().contains { entry in
                if case .text(let text) = entry.content { return text == "arrived early" }
                return false
            }
        }
        #expect(arrived, "the entry was dropped instead of waiting for the key")
    }
}

/// Keeps what was sent, so a test can replay the exact frame.
private actor CapturingTransport: SyncTransport {
    private var envelopes: [SyncEnvelope] = []

    var sent: [SyncEnvelope] { envelopes }

    func connect() async throws {}
    func disconnect() async {}
    func send(_ envelope: SyncEnvelope) async throws {
        envelopes.append(envelope)
    }
}
