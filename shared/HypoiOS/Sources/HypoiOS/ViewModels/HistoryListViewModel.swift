import Foundation
import Combine
import HypoCore

/// Backs the history list and receives entries arriving from paired devices.
@MainActor
public final class HistoryListViewModel: ObservableObject, RemoteEntryReceiving {
    @Published public private(set) var entries: [ClipboardEntry] = []
    @Published public var searchText: String = ""

    /// What became of the last send. The list inserts locally either way, so
    /// without this a send that reached nobody looks exactly like one that
    /// worked.
    @Published public private(set) var lastSendOutcome: SendOutcome?

    private let logger = HypoLogger(category: "HistoryListViewModel")
    private let store: HistoryStore
    private let transportManager: TransportManager?
    private let identity: DeviceIdentityProviding?
    private let clipboard: UIKitClipboard?

    public init(
        store: HistoryStore,
        transportManager: TransportManager? = nil,
        identity: DeviceIdentityProviding? = nil,
        clipboard: UIKitClipboard? = nil
    ) {
        self.store = store
        self.transportManager = transportManager
        self.identity = identity
        self.clipboard = clipboard
    }

    /// Whether to offer sending what is on the clipboard.
    ///
    /// Checked rather than read: iOS raises a paste prompt for content this
    /// app did not write, so reading on every foreground would ask permission
    /// every time. Detecting that something is there costs nothing, and the
    /// paste control the user then taps reads it without a prompt at all.
    @Published public private(set) var hasClipboardToSend = false

    public func refreshClipboardOffer() {
        hasClipboardToSend = clipboard?.hasTextWorthSending ?? false
    }

    public var visibleEntries: [ClipboardEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.matches(query: searchText) }
    }

    public func load() async {
        entries = await store.all()
    }

    public func handleIncomingRemoteEntry(_ entry: ClipboardEntry, duplicate: ClipboardEntry?) async {
        entries = await store.all()
    }

    public func remove(id: UUID) async {
        await store.remove(id: id)
        entries = await store.all()
    }

    public func togglePin(id: UUID) async {
        entries = await store.togglePin(id: id)
    }

    /// Puts an entry back on the clipboard, which is what tapping a row does
    /// on Android.
    public func copyToClipboard(_ entry: ClipboardEntry) {
        guard let clipboard else { return }
        switch entry.content {
        case .text(let text):
            clipboard.writeText(text)
        case .link(let url):
            clipboard.writeText(url.absoluteString)
        case .image(let metadata):
            if let data = metadata.data { _ = clipboard.writeImageData(data) }
        case .file:
            break
        }
        // What we just wrote is ours, so there is nothing new to offer sending.
        refreshClipboardOffer()
    }

    public func updateLimit(_ newLimit: Int) async {
        entries = await store.updateLimit(newLimit)
    }

    public func clearAll() async {
        await store.clear()
        entries = await store.all()
    }

    public enum SendOutcome: Equatable, Sendable {
        /// No transport or identity was injected — nothing was attempted.
        case notConfigured
        case noPairedDevices
        case sent(deviceCount: Int)
        case allFailed(deviceCount: Int)
        case partial(sent: Int, failed: Int)
    }

    /// Sends text to every paired device, then records it locally.
    ///
    /// Sending does not go through TransportManager: it has no send or
    /// broadcast method, only loadTransport(). The real path builds a
    /// SyncEngine and transmits per target, mirroring
    /// ClipboardHistoryViewModel on macOS. There is no broadcast, so one
    /// device failing must not stop the rest.
    @discardableResult
    public func sendText(_ text: String) async -> SendOutcome {
        guard let transportManager, let identity else {
            lastSendOutcome = .notConfigured
            return .notConfigured
        }

        let devices = transportManager.pairedDevices
        guard !devices.isEmpty else {
            lastSendOutcome = .noPairedDevices
            return .noPairedDevices
        }

        let entry = ClipboardEntry(
            deviceId: identity.deviceIdString,
            originPlatform: identity.platform,
            originDeviceName: identity.deviceName,
            content: .text(text),
            // Nil marks this as ours. HistoryStore treats a non-nil origin as
            // something that arrived from elsewhere, and the row renders a
            // transport badge to match — wrong for text this device just sent.
            transportOrigin: nil
        )

        let transport = transportManager.loadTransport()
        let keyProvider = KeychainDeviceKeyProvider()
        let cryptoService = CryptoService()

        // DualSyncTransport builds separate envelopes for LAN and cloud, each
        // needing its own nonce, so it has to be handed the crypto service.
        if let dualTransport = transport as? DualSyncTransport {
            dualTransport.configure(cryptoService: cryptoService, keyProvider: keyProvider)
        }

        let syncEngine = SyncEngine(
            transport: transport,
            cryptoService: cryptoService,
            keyProvider: keyProvider,
            localDeviceId: identity.deviceIdString,
            localPlatform: identity.platform
        )
        await syncEngine.establishConnection()

        let payload = ClipboardPayload(contentType: .text, data: Data(text.utf8))

        // Record it before sending, not after. The send loop awaits delivery to
        // every paired device, so a single unreachable peer used to keep the
        // entry out of this device's own history indefinitely: the user copied
        // something, the other phone received it, and the phone that sent it
        // showed nothing. What this device holds should not depend on whether
        // anyone else could be reached.
        _ = await store.insert(entry)
        entries = await store.all()
        refreshClipboardOffer()

        var sent = 0
        var failed = 0
        for device in devices {
            do {
                try await syncEngine.transmit(
                    entry: entry,
                    payload: payload,
                    targetDeviceId: device.id
                )
                transportManager.updatePairedDeviceLastSeen(device.id, lastSeen: Date())
                sent += 1
            } catch {
                failed += 1
            }
        }

        let outcome: SendOutcome
        switch (sent, failed) {
        case (0, let f): outcome = .allFailed(deviceCount: f)
        case (let s, 0): outcome = .sent(deviceCount: s)
        case (let s, let f): outcome = .partial(sent: s, failed: f)
        }
        lastSendOutcome = outcome
        return outcome
    }
}
