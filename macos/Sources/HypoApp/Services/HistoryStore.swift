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

    public func entry(withID id: UUID) -> ClipboardEntry? {
        entries.first { $0.id == id }
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
    @Published public var plainTextModeEnabled: Bool
    @Published public private(set) var pairedDevices: [PairedDevice] = []
    @Published public private(set) var encryptionKeySummary: String
    @Published public private(set) var connectionState: ConnectionState = .idle

    private let store: HistoryStore
    private let transportManager: TransportManager?
    private var connectionStateCancellable: AnyCancellable?
    private let defaults: UserDefaults
#if canImport(UserNotifications)
    private let notificationController: ClipboardNotificationScheduling?
#endif
    private var loadTask: Task<Void, Never>?
#if canImport(os)
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "transport")
#endif
    private let deviceIdentity: DeviceIdentityProviding

    private enum DefaultsKey {
        static let allowsCloudFallback = "allow_cloud_fallback"
        static let autoDeleteHours = "auto_delete_hours"
        static let appearance = "appearance_preference"
        static let pairedDevices = "paired_devices"
        static let encryptionKey = "encryption_key_summary"
        static let plainTextMode = "plain_text_mode_enabled"
    }

    public init(
        store: HistoryStore = HistoryStore(),
        transportManager: TransportManager? = nil,
        defaults: UserDefaults = .standard,
        deviceIdentity: DeviceIdentityProviding = DeviceIdentity()
    ) {
        self.store = store
        self.transportManager = transportManager
        self.defaults = defaults
        self.deviceIdentity = deviceIdentity
        self.transportPreference = transportManager?.currentPreference() ?? .lanFirst
        self.allowsCloudFallback = defaults.object(forKey: DefaultsKey.allowsCloudFallback) as? Bool ?? true
        self.autoDeleteAfterHours = defaults.object(forKey: DefaultsKey.autoDeleteHours) as? Int ?? 0
        self.plainTextModeEnabled = defaults.object(forKey: DefaultsKey.plainTextMode) as? Bool ?? false
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
            // Deduplicate devices: keep most recent by ID, then by name+platform
            let deduplicated = Self.deduplicateDevices(decoded).sorted { $0.lastSeen > $1.lastSeen }
            self.pairedDevices = deduplicated
            // Save deduplicated list directly to UserDefaults
            if let encoded = try? JSONEncoder().encode(deduplicated) {
                defaults.set(encoded, forKey: DefaultsKey.pairedDevices)
            }
        }
#if canImport(UserNotifications)
        self.notificationController = ClipboardNotificationController()
        self.notificationController?.configure(handler: self)
#endif
        
        // Listen for pairing completion notifications from TransportManager
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PairingCompleted"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            print("🔔 [HistoryStore] PairingCompleted notification received!")
            let userInfo = notification.userInfo ?? [:]
            print("   Full userInfo: \(userInfo)")
            
            // Write to debug log
            try? "🔔 [HistoryStore] PairingCompleted notification received!\n".appendToFile(path: "/tmp/hypo_debug.log")
            try? "   Full userInfo: \(userInfo)\n".appendToFile(path: "/tmp/hypo_debug.log")
            guard let deviceIdString = userInfo["deviceId"] as? String,
                  let deviceName = userInfo["deviceName"] as? String else {
                print("⚠️ [HistoryStore] PairingCompleted notification missing required fields")
                print("   userInfo keys: \(userInfo.keys)")
                print("   deviceId type: \(type(of: userInfo["deviceId"]))")
                print("   deviceName type: \(type(of: userInfo["deviceName"]))")
#if canImport(os)
                self?.logger.warning("⚠️ PairingCompleted notification missing required fields")
#endif
                return
            }
            
            print("📱 [HistoryStore] Processing device: \(deviceName), ID: \(deviceIdString)")
            
            Task { @MainActor in
                await self?.handlePairingCompleted(deviceId: deviceIdString, deviceName: deviceName)
            }
        }
        
        // Observe TransportManager's connection state
        if let transportManager = transportManager {
#if canImport(Combine)
            connectionStateCancellable = transportManager.connectionStatePublisher
                .receive(on: DispatchQueue.main)
                .assign(to: \.connectionState, on: self)
            // Set initial state
            connectionState = transportManager.connectionState
#endif
        }
        
        // Listen for connection status changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DeviceConnectionStatusChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let deviceId = userInfo["deviceId"] as? String,
                  let isOnline = userInfo["isOnline"] as? Bool else {
                return
            }
            Task { @MainActor in
                await self?.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: isOnline)
            }
        }
        
        // Listen for clipboard received events to update lastSeen
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ClipboardReceivedFromDevice"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let deviceId = userInfo["deviceId"] as? String else {
                return
            }
            Task { @MainActor in
                await self?.updateDeviceLastSeen(deviceId: deviceId)
            }
        }
    }
    
    private func handlePairingCompleted(deviceId: String, deviceName: String) async {
        print("📝 [HistoryStore] handlePairingCompleted called: \(deviceName) (\(deviceId))")
        
        // Remove any duplicates first (by ID or by name+platform)
        pairedDevices.removeAll { $0.id == deviceId || ($0.name == deviceName && $0.platform == "Android") }
        
        // Add the device
        let device = PairedDevice(
            id: deviceId,
            name: deviceName,
            platform: "Android",
            lastSeen: Date(),
            isOnline: true
        )
        pairedDevices.append(device)
        
        // Deduplicate and sort
        pairedDevices = Self.deduplicateDevices(pairedDevices).sorted { $0.lastSeen > $1.lastSeen }
        persistPairedDevices()
        print("✅ [HistoryStore] Device saved! Total paired devices: \(pairedDevices.count)")
#if canImport(os)
        logger.info("✅ Paired device saved: \(deviceName)")
#endif
    }
    
    private static func deduplicateDevices(_ devices: [PairedDevice]) -> [PairedDevice] {
        var seenById: [String: PairedDevice] = [:]
        var seenByNamePlatform: [String: PairedDevice] = [:]
        
        // Process devices, keeping the most recent for each ID or name+platform combo
        for device in devices {
            // First priority: deduplicate by ID (keep most recent)
            if let existing = seenById[device.id] {
                if device.lastSeen > existing.lastSeen {
                    seenById[device.id] = device
                }
            } else {
                seenById[device.id] = device
            }
            
            // Second priority: deduplicate by name+platform (keep most recent)
            let namePlatformKey = "\(device.name)|\(device.platform)"
            if let existing = seenByNamePlatform[namePlatformKey] {
                if device.lastSeen > existing.lastSeen {
                    seenByNamePlatform[namePlatformKey] = device
                }
            } else {
                seenByNamePlatform[namePlatformKey] = device
            }
        }
        
        // Merge results: prefer ID-based deduplication, fall back to name+platform
        var result: [PairedDevice] = []
        var addedIds = Set<String>()
        var addedNamePlatform = Set<String>()
        
        // Add devices by ID first
        for device in seenById.values {
            if !addedIds.contains(device.id) {
                result.append(device)
                addedIds.insert(device.id)
                addedNamePlatform.insert("\(device.name)|\(device.platform)")
            }
        }
        
        // Add devices by name+platform if not already added
        for device in seenByNamePlatform.values {
            let namePlatformKey = "\(device.name)|\(device.platform)"
            if !addedNamePlatform.contains(namePlatformKey) {
                result.append(device)
                addedNamePlatform.insert(namePlatformKey)
                addedIds.insert(device.id)
            }
        }
        
        return result
    }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    
    /// Force reload and deduplicate paired devices (called on app startup)
    public func reloadPairedDevices() {
        if let storedDevices = defaults.data(forKey: DefaultsKey.pairedDevices),
           let decoded = try? JSONDecoder().decode([PairedDevice].self, from: storedDevices) {
            let beforeCount = decoded.count
            let deduplicated = Self.deduplicateDevices(decoded).sorted { $0.lastSeen > $1.lastSeen }
            let afterCount = deduplicated.count
            if beforeCount != afterCount {
                print("🔄 [HistoryStore] Reload deduplication: \(beforeCount) → \(afterCount) devices")
            }
            self.pairedDevices = deduplicated
            if let encoded = try? JSONEncoder().encode(deduplicated) {
                defaults.set(encoded, forKey: DefaultsKey.pairedDevices)
            }
        }
    }

    public func start() async {
        // Reload and deduplicate paired devices on startup
        reloadPairedDevices()
#if canImport(UserNotifications)
        notificationController?.requestAuthorizationIfNeeded()
#endif
        await transportManager?.ensureLanDiscoveryActive()
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
        guard let transportManager = transportManager,
              let report = transportManager.handleDeepLink(url) else { return }
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
#if canImport(UserNotifications)
        notificationController?.deliverNotification(for: entry)
#endif
        
        // ✅ Auto-sync to paired devices
        await syncToPairedDevices(entry)
    }
    
    private func syncToPairedDevices(_ entry: ClipboardEntry) async {
        guard !pairedDevices.isEmpty, let transportManager = transportManager else { return }
        
        // Convert clipboard entry to payload
        let payload: ClipboardPayload
        switch entry.content {
        case .text(let text):
            payload = ClipboardPayload(
                contentType: .text,
                data: Data(text.utf8),
                metadata: ["device_id": entry.originDeviceId, "device_name": entry.originDeviceName ?? ""]
            )
        case .link(let url):
            payload = ClipboardPayload(
                contentType: .link,
                data: Data(url.absoluteString.utf8),
                metadata: ["device_id": entry.originDeviceId, "device_name": entry.originDeviceName ?? ""]
            )
        case .image, .file:
            // Skip images/files for now (would need more complex handling)
            return
        }
        
        // Get sync engine with transport
        let transport = transportManager.loadTransport()
        let keyProvider = KeychainDeviceKeyProvider()
        let syncEngine = SyncEngine(
            transport: transport,
            keyProvider: keyProvider,
            localDeviceId: deviceIdentity.deviceIdString
        )
        
        // Ensure transport is connected
        await syncEngine.establishConnection()
        
        // Send to each paired device
        for device in pairedDevices {
            guard device.isOnline else { continue }
            do {
                try await syncEngine.transmit(entry: entry, payload: payload, targetDeviceId: device.id)
#if canImport(os)
                logger.info("✅ Synced clipboard to device: \(device.name, privacy: .public)")
#endif
                // Update lastSeen timestamp after successful sync
                await updateDeviceLastSeen(deviceId: device.id)
            } catch {
#if canImport(os)
                logger.error("❌ Failed to sync to \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
#endif
            }
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
        transportManager?.update(preference: preference)
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
    
    private func updateDeviceOnlineStatus(deviceId: String, isOnline: Bool) async {
        guard let index = pairedDevices.firstIndex(where: { $0.id == deviceId }) else {
            print("⚠️ [HistoryStore] Cannot update online status - device not found: \(deviceId)")
            return
        }
        let device = pairedDevices[index]
        if device.isOnline != isOnline {
            print("🔄 [HistoryStore] Updating device \(device.name) online status: \(device.isOnline) → \(isOnline)")
            pairedDevices[index] = PairedDevice(
                id: device.id,
                name: device.name,
                platform: device.platform,
                lastSeen: isOnline ? Date() : device.lastSeen,
                isOnline: isOnline
            )
            persistPairedDevices()
        }
    }
    
    /// Update lastSeen timestamp for a device (public method for external callers)
    public func updateDeviceLastSeen(deviceId: String) async {
        guard let index = pairedDevices.firstIndex(where: { $0.id == deviceId }) else {
            print("⚠️ [HistoryStore] Cannot update lastSeen - device not found: \(deviceId)")
            return
        }
        let device = pairedDevices[index]
        let now = Date()
        // Only update if it's been more than 1 second since last update (avoid excessive updates)
        if now.timeIntervalSince(device.lastSeen) > 1.0 {
            print("🔄 [HistoryStore] Updating device \(device.name) lastSeen: \(device.lastSeen) → \(now)")
            pairedDevices[index] = PairedDevice(
                id: device.id,
                name: device.name,
                platform: device.platform,
                lastSeen: now,
                isOnline: device.isOnline
            )
            persistPairedDevices()
        }
    }


    public func makeRemotePairingViewModel() -> RemotePairingViewModel {
        RemotePairingViewModel(identity: deviceIdentity) { [weak self] device in
            self?.registerPairedDevice(device)
        }
    }

    public func pairingParameters() -> (service: String, port: Int, relayHint: URL?) {
        let config = transportManager?.currentLanConfiguration()
        let domain = config?.domain ?? "local."
        let serviceType = config?.serviceType ?? "_hypo._tcp."
        let serviceName = config?.serviceName ?? ProcessInfo.processInfo.hostName
        let port = config?.port ?? 7010
        let service = "\(serviceName).\(serviceType)\(domain)"

        let relayConfig = CloudRelayDefaults.staging()
        var relayComponents = URLComponents(url: relayConfig.url, resolvingAgainstBaseURL: false)
        if relayComponents?.scheme == "wss" { relayComponents?.scheme = "https" }
        let relayHint = relayComponents?.url
        return (service: service, port: port, relayHint: relayHint)
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
    
    /// Returns the local device ID for comparing entry origins
    public var localDeviceId: String {
        deviceIdentity.deviceIdString
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
        // Always deduplicate before persisting
        let deduplicated = Self.deduplicateDevices(pairedDevices)
        if deduplicated.count != pairedDevices.count {
            print("🔄 [HistoryStore] Deduplicating before persist: \(pairedDevices.count) → \(deduplicated.count) devices")
            pairedDevices = deduplicated
        }
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

#if canImport(UserNotifications)
extension ClipboardHistoryViewModel: ClipboardNotificationHandling {
    public func handleNotificationCopy(for id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            guard let entry = await self.store.entry(withID: id) else { return }
#if canImport(AppKit)
            await MainActor.run {
                self.copyToPasteboard(entry)
            }
#endif
        }
    }

    public func handleNotificationDelete(for id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            await self.remove(id: id)
        }
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
    public let id: String
    public let name: String
    public let platform: String
    public let lastSeen: Date
    public let isOnline: Bool

    public init(id: String = UUID().uuidString, name: String, platform: String, lastSeen: Date, isOnline: Bool) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSeen = lastSeen
        self.isOnline = isOnline
    }
}
