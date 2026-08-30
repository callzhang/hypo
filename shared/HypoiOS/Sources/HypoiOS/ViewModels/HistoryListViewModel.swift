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

    /// Sends whatever was copied while the app was away.
    ///
    /// Called when the app becomes active, which is the same moment Android
    /// checks the clipboard in onResume — neither platform can watch it from
    /// the background. Does nothing when this app wrote the current contents,
    /// so an entry that just arrived is not sent straight back.
    public func sendClipboardIfChanged() async {
        guard let clipboard, let text = await clipboard.readForegroundText() else { return }
        await sendText(text)
    }

    /// Filtered through `ClipboardEntry.matches(query:)`, the same predicate the
    /// macOS list uses, so search behaves identically on both platforms. It
    /// looks at the device id and the full text, link, image alt text or file
    /// name — where filtering on `content.previewDescription` would miss any
    /// match past the 100 characters that preview truncates at, and would match
    /// images against a formatted "name · PNG · 1.2 MB" string rather than
    /// their alt text.
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
            transportOrigin: .lan
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

        _ = await store.insert(entry)
        entries = await store.all()

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
