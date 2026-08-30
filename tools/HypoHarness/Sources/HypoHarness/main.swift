import Foundation
import CryptoKit
import HypoCore

// A development harness for exercising HypoCore against a real peer — the
// Swift counterpart to windows/tools/Hypo.Harness. Not a product: keys live in
// memory and vanish on exit, which is why pairing and listening are one
// command rather than two.
//
//   show     show a pairing code, then listen for clipboard traffic
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
    try await runShow()
default:
    print("usage: HypoHarness show")
    exit(2)
}

// MARK: -

func runShow() async throws {
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
    let code = try await client.createPairingCode(
        initiatorDeviceId: payload.peerDeviceId,
        initiatorDeviceName: deviceName,
        initiatorPublicKey: payload.peerPublicKey
    )

    print("")
    print("  Pairing code: \(code.code)")
    print("  Enter it on the other device. Expires \(code.expiresAt).")
    // Written out so an automated driver can pick it up; a human just reads
    // the line above.
    if let path = ProcessInfo.processInfo.environment["HYPO_CODE_FILE"] {
        try? code.code.write(toFile: path, atomically: true, encoding: .utf8)
        print("  (also written to \(path))")
    }
    print("")

    // Start listening before pairing finishes: the other device may dial the
    // moment it has a key, and a listener that appears late is a race.
    let server = await MainActor.run { LanWebSocketServer(localDeviceId: deviceId) }
    try await MainActor.run { try server.start(port: lanPort) }
    let boundPort = try await server.waitForPort(timeout: 5.0)
    print("Listening on port \(boundPort)")

    await MainActor.run {
        let publisher = BonjourPublisher()
        publisher.start(with: BonjourPublisher.Configuration(
            serviceName: deviceName,
            port: Int(boundPort),
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

    let inbox = await MainActor.run { () -> HarnessInbox in
        let inbox = HarnessInbox(deviceId: deviceId, keyProvider: keyProvider)
        server.delegate = inbox
        return inbox
    }
    _ = inbox

    // Answer the challenge when it arrives.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    for _ in 0..<120 {
        if pairedPeer.withLock({ $0 }) != nil { break }
        do {
            let json = try await client.pollChallenge(
                code: code.code,
                initiatorDeviceId: payload.peerDeviceId
            )
            let message = try decoder.decode(PairingChallengeMessage.self, from: Data(json.utf8))
            guard let ack = await session.handleChallenge(message) else {
                print("Challenge rejected.")
                break
            }
            try await client.submitAck(
                code: code.code,
                initiatorDeviceId: payload.peerDeviceId,
                ackJSON: String(decoding: try encoder.encode(ack), as: UTF8.self)
            )
            print("Paired with \(ack.responderDeviceName) (\(ack.responderDeviceId.uuidString.lowercased()))")
        } catch PairingRelayClient.Error.challengeNotReady {
            try? await Task.sleep(for: .milliseconds(1000))
        } catch {
            print("Pairing failed: \(error.localizedDescription)")
            break
        }
    }

    if let peer = pairedPeer.withLock({ $0 }), let text = sendText {
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

    // Sends repeatedly rather than once.
    //
    // The peer dials as soon as it discovers this harness, which is before it
    // has finished pairing — so the first send can arrive while the other side
    // still has no key for us, and it is dropped with nothing to retry it. A
    // real user copying a second thing would recover; a single send does not.
    var delivered = 0
    for attempt in 1...20 {
        do {
            try await engine.transmit(entry: entry, payload: payload, targetDeviceId: peer)
            delivered += 1
            print("Sent \"\(text)\" to \(peer) (attempt \(attempt))")
        } catch {
            if attempt == 20 && delivered == 0 {
                print("Could not send after 20 tries: \(error.localizedDescription)")
                return
            }
        }
        try? await Task.sleep(for: .seconds(4))
    }
}

enum HarnessError: Error { case noPayload }

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

    @MainActor
    init(deviceId: String, keyProvider: InMemoryDeviceKeyProvider) {
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

    func server(_ server: LanWebSocketServer, didReceivePairingChallenge challenge: PairingChallengeMessage, from connection: UUID) {}
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
