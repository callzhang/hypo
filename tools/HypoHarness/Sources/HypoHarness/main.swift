import Foundation
import CryptoKit
import HypoCore

// A development harness for exercising HypoCore against a real peer — the
// Swift counterpart to windows/tools/Hypo.Harness. Not a product: keys live in
// memory and vanish on exit, which is why pairing and listening are one
// command rather than two.
//
//   show     show a pairing code, then listen for clipboard traffic over LAN
//   relay    the same, but over the cloud relay only — no listener, no Bonjour,
//            so the peer has no LAN route and must use the relay. Needs
//            RELAY_WS_AUTH_TOKEN in the environment.
//
// Environment:
//   HYPO_DEVICE_NAME   what to call this peer (default "Hypo Harness")
//   HYPO_LAN_PORT      port to listen on (default 7010)
//   HYPO_SEND_TEXT     if set, send this once a device connects
//
// Exists because pairing is a two-device act and the other device cannot be a
// unit test: something has to hold a real socket, advertise over Bonjour and
// answer for a real device id.

// Line-buffered: this prints a pairing code someone is waiting to read, and
// full buffering hides it until the process exits.
setvbuf(stdout, nil, _IOLBF, 0)

let relayURL = URL(string: "https://hypo.fly.dev")!
let deviceName = ProcessInfo.processInfo.environment["HYPO_DEVICE_NAME"] ?? "Hypo Harness"
let lanPort = Int(ProcessInfo.processInfo.environment["HYPO_LAN_PORT"] ?? "") ?? 7010
let sendText = ProcessInfo.processInfo.environment["HYPO_SEND_TEXT"]

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "show"

switch command {
case "show":
    try await runShow(overRelay: false)
case "relay":
    try await runShow(overRelay: true)
default:
    print("usage: HypoHarness show | relay")
    exit(2)
}

// MARK: -

func runShow(overRelay: Bool) async throws {
    let identity = UUID()
    let deviceId = identity.uuidString.lowercased()
    let keyProvider = InMemoryDeviceKeyProvider()
    let pairedPeer = Locked<String?>(nil)

    print("Harness device id: \(deviceId)")
    print("Harness name:      \(deviceName)")

    let session = await MainActor.run {
        PairingSession(
            identity: identity,
            storeSharedKey: { key, peerDeviceId in
                Task { await keyProvider.setKey(key, for: peerDeviceId) }
                pairedPeer.withLock { $0 = peerDeviceId }
            }
        )
    }

    try await MainActor.run {
        try session.start(with: PairingSession.Configuration(
            service: "_hypo._tcp.local",
            port: lanPort,
            relayHint: relayURL,
            deviceName: deviceName
        ))
    }
    let payload = try await MainActor.run { () -> PairingPayload in
        guard let payload = session.currentPayload() else {
            throw HarnessError.noPayload
        }
        return payload
    }

    let client = PairingRelayClient(baseURL: relayURL)

    // Start listening before pairing finishes: the other device may dial the
    // moment it has a key, and a listener that appears late is a race.
    let server = await MainActor.run { LanWebSocketServer(localDeviceId: deviceId) }
    var boundPort: Int = 0
    if !overRelay {
        try await MainActor.run { try server.start(port: lanPort) }
        boundPort = try await server.waitForPort(timeout: 5.0)
        print("Listening on port \(boundPort)")
    } else {
        print("Relay mode: no LAN listener and no Bonjour, so the peer has to use the relay.")
    }

    let cloudTransport: CloudRelayTransport? = overRelay
        ? await MainActor.run { CloudRelayTransport(configuration: CloudRelayDefaults.production()) }
        : nil
    if let cloudTransport {
        await MainActor.run {
            cloudTransport.setOnIncomingMessage { data, origin in
                await RelayInboxBox.shared.handle(data, origin)
            }
        }
        do {
            try await cloudTransport.connect()
            print("Connected to the relay.")
        } catch {
            print("Could not connect to the relay: \(error.localizedDescription)")
            print("Is RELAY_WS_AUTH_TOKEN set? Without it the relay answers 401.")
            exit(1)
        }
    }

    if !overRelay { await MainActor.run {
        let publisher = BonjourPublisher()
        publisher.start(with: BonjourPublisher.Configuration(
            serviceName: deviceName,
            port: boundPort,
            version: "1.0.0",
            fingerprint: "",
            protocols: ["hypo/1"],
            deviceId: deviceId,
            publicKey: payload.peerPublicKey.base64EncodedString()
        ))
        // Held for the process lifetime; the harness never stops advertising.
        PublisherBox.shared.keep(publisher)
    }
    print("Advertising _hypo._tcp as \"\(deviceName)\"")
    }

    let inbox = await MainActor.run { () -> HarnessInbox in
        let inbox = HarnessInbox(
            deviceId: deviceId,
            keyProvider: keyProvider,
            session: session,
            server: server,
            onPaired: { peerId in pairedPeer.withLock { $0 = peerId } }
        )
        server.delegate = inbox
        InboxBox.shared.keep(inbox)
        return inbox
    }
    await RelayInboxBox.shared.adopt(inbox)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    // Codes expire in about a minute. Rather than showing one and giving up,
    // mint a new one whenever the relay says the old is gone — a person who
    // walks away mid-pairing should not have to restart the process, and an
    // automated driver should not have to race the clock.
    codeLoop: while pairedPeer.withLock({ $0 }) == nil {
        let code = try await client.createPairingCode(
            initiatorDeviceId: payload.peerDeviceId,
            initiatorDeviceName: deviceName,
            initiatorPublicKey: payload.peerPublicKey
        )
        print("")
        print("  Pairing code: \(code.code)")
        print("  Enter it on the other device. Expires \(code.expiresAt).")
        if let path = ProcessInfo.processInfo.environment["HYPO_CODE_FILE"] {
            try? code.code.write(toFile: path, atomically: true, encoding: .utf8)
            print("  (also written to \(path))")
        }
        print("")

        while pairedPeer.withLock({ $0 }) == nil {
            do {
                let json = try await client.pollChallenge(
                    code: code.code,
                    initiatorDeviceId: payload.peerDeviceId
                )
                let message = try decoder.decode(PairingChallengeMessage.self, from: Data(json.utf8))
                guard let ack = await session.handleChallenge(message) else {
                    print("Challenge rejected.")
                    break codeLoop
                }
                try await client.submitAck(
                    code: code.code,
                    initiatorDeviceId: payload.peerDeviceId,
                    ackJSON: String(decoding: try encoder.encode(ack), as: UTF8.self)
                )
                print("Paired with the device that claimed \(code.code)")
            } catch PairingRelayClient.Error.challengeNotReady {
                try? await Task.sleep(for: .milliseconds(1000))
            } catch {
                print("Code \(code.code) is no longer usable (\(error.localizedDescription)); issuing another.")
                continue codeLoop
            }
        }
    }

    if let peer = pairedPeer.withLock({ $0 }), let text = sendText, let cloudTransport {
        print("Waiting to send \"\(text)\" to \(peer) over the relay…")
        try await sendOverRelay(
            text: text,
            to: peer,
            from: deviceId,
            transport: cloudTransport,
            keyProvider: keyProvider
        )
    } else if let peer = pairedPeer.withLock({ $0 }), let text = sendText {
        print("Waiting for \(peer) to connect so it can be sent \"\(text)\"…")
        try await sendWhenConnected(
            text: text,
            to: peer,
            from: deviceId,
            server: server,
            keyProvider: keyProvider
        )
    }

    print("Holding. Copy something on the other device; anything that arrives prints here. Ctrl-C to stop.")
    while true {
        try await Task.sleep(for: .seconds(3600))
    }
}

func sendWhenConnected(
    text: String,
    to peer: String,
    from deviceId: String,
    server: LanWebSocketServer,
    keyProvider: InMemoryDeviceKeyProvider
) async throws {
    let transport = await MainActor.run { LanSyncTransport(server: server) }
    let engine = SyncEngine(
        transport: transport,
        keyProvider: keyProvider,
        localDeviceId: deviceId
    )
    await engine.establishConnection()

    let entry = ClipboardEntry(
        deviceId: deviceId,
        originDeviceName: deviceName,
        content: .text(text),
        transportOrigin: .lan
    )
    let payload = ClipboardPayload(contentType: .text, data: Data(text.utf8))

    // Retries until one send lands, then stops.
    //
    // It used to keep sending every few seconds, which was a workaround for a
    // race that pairing over the LAN removes. Repeating has a cost: every
    // arrival is written to the peer's clipboard, so from that device's point
    // of view the clipboard is always something it wrote itself, and it stops
    // offering to send anything of its own.
    for attempt in 1...20 {
        do {
            try await engine.transmit(entry: entry, payload: payload, targetDeviceId: peer)
            print("Sent \"\(text)\" to \(peer)")
            return
        } catch {
            if attempt == 20 {
                print("Could not send after 20 tries: \(error.localizedDescription)")
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

func sendOverRelay(
    text: String,
    to peer: String,
    from deviceId: String,
    transport: CloudRelayTransport,
    keyProvider: InMemoryDeviceKeyProvider
) async throws {
    let engine = SyncEngine(
        transport: transport,
        keyProvider: keyProvider,
        localDeviceId: deviceId
    )
    await engine.establishConnection()

    let entry = ClipboardEntry(
        deviceId: deviceId,
        originDeviceName: deviceName,
        content: .text(text),
        transportOrigin: .cloud
    )
    let payload = ClipboardPayload(contentType: .text, data: Data(text.utf8))

    for attempt in 1...20 {
        do {
            try await engine.transmit(entry: entry, payload: payload, targetDeviceId: peer)
            print("Sent \"\(text)\" to \(peer) over the relay")
            return
        } catch {
            if attempt == 20 {
                print("Could not send over the relay after 20 tries: \(error.localizedDescription)")
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

/// Routes relay traffic into the same inbox the LAN server uses, so arriving
/// content prints the same way whichever route it took.
actor RelayInboxBox {
    static let shared = RelayInboxBox()
    private var inbox: HarnessInbox?

    func adopt(_ inbox: HarnessInbox) { self.inbox = inbox }

    func handle(_ data: Data, _ origin: TransportOrigin) async {
        guard let inbox else { return }
        await inbox.handleRelayFrame(data)
    }
}

enum HarnessError: Error { case noPayload }

/// Keeps the inbox alive; the server holds its delegate weakly.
@MainActor
final class InboxBox {
    static let shared = InboxBox()
    private var inboxes: [AnyObject] = []
    func keep(_ inbox: AnyObject) { inboxes.append(inbox) }
}

/// Keeps the Bonjour publisher alive. Top-level code cannot hold main-actor
/// globals, and a publisher that gets deallocated stops advertising.
@MainActor
final class PublisherBox {
    static let shared = PublisherBox()
    private var publishers: [BonjourPublisher] = []
    func keep(_ publisher: BonjourPublisher) { publishers.append(publisher) }
}

/// Prints whatever arrives, which is the whole point of the listening side.
final class HarnessInbox: LanWebSocketServerDelegate, @unchecked Sendable {
    private let handler: IncomingClipboardHandler
    private let session: PairingSession
    private let server: LanWebSocketServer
    private let onPaired: @Sendable (String) -> Void

    @MainActor
    init(
        deviceId: String,
        keyProvider: InMemoryDeviceKeyProvider,
        session: PairingSession,
        server: LanWebSocketServer,
        onPaired: @escaping @Sendable (String) -> Void
    ) {
        self.session = session
        self.server = server
        self.onPaired = onPaired
        let engine = SyncEngine(
            transport: SilentTransport(),
            keyProvider: keyProvider,
            localDeviceId: deviceId
        )
        self.handler = IncomingClipboardHandler(
            syncEngine: engine,
            historyStore: HistoryStore(persistence: InMemoryHistoryPersistence()),
            dispatcher: ClipboardEventDispatcher(),
            clipboard: PrintingClipboard()
        )
    }

    /// Answers a challenge that arrived over the LAN, which is how a device
    /// pairs with this one by tapping it in a list rather than typing a code.
    func server(_ server: LanWebSocketServer, didReceivePairingChallenge challenge: PairingChallengeMessage, from connection: UUID) {
        print("Pairing challenge over LAN from \(challenge.initiatorDeviceName)")
        Task { @MainActor in
            guard let ack = await self.session.handleChallenge(challenge) else {
                print("Rejected the LAN pairing challenge.")
                return
            }
            do {
                try self.server.sendPairingAck(ack, to: connection)
                self.onPaired(challenge.initiatorDeviceId)
                print("Paired over LAN with \(challenge.initiatorDeviceName)")
            } catch {
                print("Could not send the pairing ack: \(error.localizedDescription)")
            }
        }
    }
    func server(_ server: LanWebSocketServer, didAcceptConnection id: UUID) {
        print("A device connected.")
    }
    func server(_ server: LanWebSocketServer, didCloseConnection id: UUID) {
        print("A device disconnected.")
    }
    func server(_ server: LanWebSocketServer, didIdentifyConnection id: UUID, deviceId: String) {
        print("Connection identified as \(deviceId)")
    }
    func server(_ server: LanWebSocketServer, didReceiveClipboardData data: Data, from connection: UUID) {
        Task { @MainActor in await handler.handle(data) }
    }

    func handleRelayFrame(_ data: Data) async {
        await MainActor.run { Task { await self.handler.handle(data) } }
    }
}

final class SilentTransport: SyncTransport {
    func connect() async throws {}
    func send(_ envelope: SyncEnvelope) async throws {}
    func disconnect() async {}
}

/// The harness has no clipboard of its own; arriving content is printed.
@MainActor
final class PrintingClipboard: SystemClipboard {
    var changeCount: Int = 0
    func clear() {}
    func writeText(_ text: String) {
        changeCount += 1
        print("RECEIVED text: \(text)")
        // Written out so an automated driver can see it; a human reads the
        // line above.
        if let path = ProcessInfo.processInfo.environment["HYPO_RECEIVED_FILE"] {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    func writeImageData(_ data: Data) -> Bool {
        changeCount += 1
        print("RECEIVED image: \(data.count) bytes")
        return true
    }
    func writeFileURL(_ url: URL) {
        changeCount += 1
        print("RECEIVED file: \(url.lastPathComponent)")
    }
    func currentText() -> String? { nil }
    func containsImage() -> Bool { false }
    func imagePixelSize(from data: Data) -> (width: Int, height: Int)? { nil }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
