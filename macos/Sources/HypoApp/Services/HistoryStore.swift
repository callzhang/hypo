import Foundation

#if canImport(Combine)
import Combine
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os.log
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public actor HistoryStore {
    private var entries: [ClipboardEntry] = []
    private var maxEntries: Int

    public init(maxEntries: Int = 200) {
        self.maxEntries = max(1, maxEntries)
    }

    @discardableResult
    public func insert(_ entry: ClipboardEntry) -> [ClipboardEntry] {
        if let index = entries.firstIndex(where: { $0.id == entry.id || $0.content == entry.content }) {
            entries.remove(at: index)
        }
        entries.append(entry)
        sortEntries()
        trimIfNeeded()
        return entries
    }

    public func all() -> [ClipboardEntry] {
        entries
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public func clear() {
        entries.removeAll()
    }

    @discardableResult
    public func updatePinState(id: UUID, isPinned: Bool) -> [ClipboardEntry] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries }
        entries[index].isPinned = isPinned
        sortEntries()
        return entries
    }

    @discardableResult
    public func updateLimit(_ newLimit: Int) -> [ClipboardEntry] {
        maxEntries = max(1, newLimit)
        trimIfNeeded()
        return entries
    }

    public func limit() -> Int { maxEntries }

    private func sortEntries() {
        entries.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private func trimIfNeeded() {
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }
}

#if canImport(Combine)
#if canImport(SwiftUI)
import SwiftUI
#endif

@MainActor
public final class ClipboardHistoryViewModel: ObservableObject {
    @Published public private(set) var items: [ClipboardEntry] = []
    @Published public private(set) var latestItem: ClipboardEntry?
    @Published public var historyLimit: Int = 200
    @Published public var transportPreference: TransportPreference
    @Published public var allowsCloudFallback: Bool
    @Published public var appearancePreference: AppearancePreference
    @Published public var autoDeleteAfterHours: Int
    @Published public private(set) var pairedDevices: [PairedDevice] = []
    @Published public private(set) var encryptionKeySummary: String

    private let store: HistoryStore
    private let transportManager: TransportManager
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
#if canImport(os)
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "transport")
#endif

    private enum DefaultsKey {
        static let allowsCloudFallback = "allow_cloud_fallback"
        static let autoDeleteHours = "auto_delete_hours"
        static let appearance = "appearance_preference"
        static let pairedDevices = "paired_devices"
        static let encryptionKey = "encryption_key_summary"
    }

    public init(
        store: HistoryStore = HistoryStore(),
        transportManager: TransportManager = TransportManager(provider: DefaultTransportProvider()),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.transportManager = transportManager
        self.defaults = defaults
        self.transportPreference = transportManager.currentPreference()
        self.allowsCloudFallback = defaults.object(forKey: DefaultsKey.allowsCloudFallback) as? Bool ?? true
        self.autoDeleteAfterHours = defaults.object(forKey: DefaultsKey.autoDeleteHours) as? Int ?? 0
        if let rawAppearance = defaults.string(forKey: DefaultsKey.appearance),
           let appearance = AppearancePreference(rawValue: rawAppearance) {
            self.appearancePreference = appearance
        } else {
            self.appearancePreference = .system
        }
        if let storedKey = defaults.string(forKey: DefaultsKey.encryptionKey) {
            self.encryptionKeySummary = storedKey
        } else {
            let generated = Self.generateEncryptionKey()
            self.encryptionKeySummary = generated
            defaults.set(generated, forKey: DefaultsKey.encryptionKey)
        }
        if let storedDevices = defaults.data(forKey: DefaultsKey.pairedDevices),
           let decoded = try? JSONDecoder().decode([PairedDevice].self, from: storedDevices) {
            self.pairedDevices = decoded.sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    deinit {
        loadTask?.cancel()
    }

    public func start() async {
        await transportManager.ensureLanDiscoveryActive()
        loadTask?.cancel()
        loadTask = Task { [store] in
            async let snapshotTask = store.all()
            async let limitTask = store.limit()
            let snapshot = await snapshotTask
            let limit = await limitTask
            await MainActor.run {
                self.items = snapshot
                self.latestItem = snapshot.first
                self.historyLimit = limit
            }
        }
    }

    public func handleDeepLink(_ url: URL) async {
        guard let report = transportManager.handleDeepLink(url) else { return }
#if canImport(os)
        logger.info("\n\(report, privacy: .public)")
#else
        print(report)
#endif
    }

    public func add(_ entry: ClipboardEntry) async {
        if autoDeleteAfterHours > 0 {
            let expireDate = Date().addingTimeInterval(TimeInterval(autoDeleteAfterHours) * 3600)
            scheduleExpiry(for: entry.id, date: expireDate)
        }
        let updated = await store.insert(entry)
        await MainActor.run {
            self.items = updated
            self.latestItem = updated.first
        }
    }

    public func remove(id: UUID) async {
        await store.remove(id: id)
        let snapshot = await store.all()
        await MainActor.run {
            self.items = snapshot
            self.latestItem = snapshot.first
        }
    }

    public func clearHistory() {
        Task {
            await store.clear()
            await MainActor.run {
                self.items.removeAll()
                self.latestItem = nil
            }
        }
    }

    public func updateHistoryLimit(_ newValue: Int) {
        let boundedValue = max(1, newValue)
        Task {
            let updated = await store.updateLimit(boundedValue)
            await MainActor.run {
                self.historyLimit = boundedValue
                self.items = updated
                self.latestItem = updated.first
            }
        }
    }

    public func togglePin(_ entry: ClipboardEntry) {
        Task {
            let updated = await store.updatePinState(id: entry.id, isPinned: !entry.isPinned)
            await MainActor.run {
                self.items = updated
                self.latestItem = updated.first
            }
        }
    }

    public func updateTransportPreference(_ preference: TransportPreference) {
        transportManager.update(preference: preference)
        transportPreference = preference
    }

    public func setAllowsCloudFallback(_ allowed: Bool) {
        allowsCloudFallback = allowed
        defaults.set(allowed, forKey: DefaultsKey.allowsCloudFallback)
    }

    public func setAutoDelete(hours: Int) {
        autoDeleteAfterHours = max(0, hours)
        defaults.set(autoDeleteAfterHours, forKey: DefaultsKey.autoDeleteHours)
    }

    public func updateAppearance(_ appearance: AppearancePreference) {
        appearancePreference = appearance
        defaults.set(appearance.rawValue, forKey: DefaultsKey.appearance)
    }

    public func registerPairedDevice(_ device: PairedDevice) {
        if let index = pairedDevices.firstIndex(where: { $0.id == device.id }) {
            pairedDevices[index] = device
        } else if let existingIndex = pairedDevices.firstIndex(where: { $0.name == device.name && $0.platform == device.platform }) {
            pairedDevices[existingIndex] = device
        } else {
            pairedDevices.append(device)
        }
        pairedDevices.sort { $0.lastSeen > $1.lastSeen }
        persistPairedDevices()
    }

    public func pairDevice(name: String, platform: String) {
        let device = PairedDevice(name: name, platform: platform, lastSeen: Date(), isOnline: true)
        registerPairedDevice(device)
    }

    public func removePairedDevice(_ device: PairedDevice) {
        pairedDevices.removeAll { $0.id == device.id }
        persistPairedDevices()
    }

    public func regenerateEncryptionKey() {
        let key = Self.generateEncryptionKey()
        encryptionKeySummary = key
        defaults.set(key, forKey: DefaultsKey.encryptionKey)
    }

    #if canImport(AppKit)
    public func copyEncryptionKeyToPasteboard() {
        guard !encryptionKeySummary.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(encryptionKeySummary, forType: .string)
    }
    #endif

    public func copyToPasteboard(_ entry: ClipboardEntry) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch entry.content {
        case .text(let value):
            pasteboard.setString(value, forType: .string)
        case .link(let url):
            pasteboard.setString(url.absoluteString, forType: .URL)
        case .image:
            if let data = entry.previewData() {
                pasteboard.setData(data, forType: .png)
            }
        case .file(let metadata):
            if let url = metadata.url {
                pasteboard.writeObjects([url as NSURL])
            }
        }
        #endif
    }

    #if canImport(AppKit)
    public func itemProvider(for entry: ClipboardEntry) -> NSItemProvider? {
        switch entry.content {
        case .text(let value):
            return NSItemProvider(object: value as NSString)
        case .link(let url):
            return NSItemProvider(object: url as NSURL)
        case .image:
            if let data = entry.previewData() {
                if #available(macOS 11.0, *) {
                    return NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
                } else {
                    return NSItemProvider(item: data as NSData, typeIdentifier: "public.png")
                }
            }
            return nil
        case .file(let metadata):
            if let url = metadata.url {
                return NSItemProvider(object: url as NSURL)
            }
            return nil
        }
    }
    #endif

    private func scheduleExpiry(for id: UUID, date: Date) {
        let delay = date.timeIntervalSinceNow
        guard delay > 0 else { return }
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.remove(id: id)
        }
    }

    private func persistPairedDevices() {
        guard let data = try? JSONEncoder().encode(pairedDevices) else { return }
        defaults.set(data, forKey: DefaultsKey.pairedDevices)
    }

    private static func generateEncryptionKey() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

#if canImport(AppKit)
extension ClipboardHistoryViewModel: ClipboardMonitorDelegate {
    nonisolated public func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry) {
        Task { await self.add(entry) }
    }
}
#endif

public extension ClipboardHistoryViewModel {
    enum AppearancePreference: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        public var id: String { rawValue }

        #if canImport(SwiftUI)
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
        #endif
    }
}

#endif

public struct PairedDevice: Identifiable, Equatable, Codable {
    public let id: UUID
    public let name: String
    public let platform: String
    public let lastSeen: Date
    public let isOnline: Bool

    public init(id: UUID = UUID(), name: String, platform: String, lastSeen: Date, isOnline: Bool) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSeen = lastSeen
        self.isOnline = isOnline
    }
}
