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
    private let logger = HypoLogger(category: "HistoryStore")
    private var entries: [ClipboardEntry] = []
    private var maxEntries: Int
    private let defaults: UserDefaults
    private static let entriesKey = "com.hypo.clipboard.history_entries"

    public init(maxEntries: Int = 200, defaults: UserDefaults = .standard) {
        self.maxEntries = max(1, maxEntries)
        self.defaults = defaults
        // Load persisted entries on init (nonisolated context, so we do it synchronously)
        if let data = defaults.data(forKey: Self.entriesKey),
           let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) {
            let count = decoded.count
            self.entries = decoded
            // Note: sortEntries() and trimIfNeeded() are actor-isolated, so we'll call them in the first insert/query
            #if canImport(os)
            let logger = HypoLogger(category: "history")
            logger.info("✅ Loaded \(count) clipboard entries from persistence")
            #endif
        }
    }
    
    private func persistEntries() {
        if let encoded = try? JSONEncoder().encode(self.entries) {
            defaults.set(encoded, forKey: Self.entriesKey)
            logger.info("💾 [HistoryStore] Persisted \(self.entries.count) clipboard entries")
            #if canImport(os)
            let logger = HypoLogger(category: "history")
            logger.debug("💾 Persisted \(self.entries.count) clipboard entries")
            #endif
        } else {
            logger.error("❌ [HistoryStore] Failed to encode entries for persistence")
        }
    }

    @discardableResult
    public func insert(_ entry: ClipboardEntry) -> [ClipboardEntry] {
        let now = Date()
        
        // Simplified duplicate detection (no time windows):
        // 1. If new message matches the current clipboard (latest entry) → discard
        // 2. If new message matches something in history → move that history item to the top
        // 3. Otherwise → add new entry
        
        // Check if matches current clipboard (latest entry)
        if let latestEntry = entries.first {
            if entry.matchesContent(latestEntry) {
                logger.info("⏭️ [HistoryStore] New message matches current clipboard, discarding: \(entry.previewText.prefix(50))")
                return entries
            }
        }
        
        // Check if matches something in history (excluding the latest entry)
        let historyEntries = Array(entries.dropFirst()) // Skip latest entry
        if let matchingEntry = historyEntries.first(where: { existingEntry in
            entry.matchesContent(existingEntry)
        }) {
            // Found matching entry in history - move it to the top
            if let index = entries.firstIndex(where: { $0.id == matchingEntry.id }) {
                // Update timestamp to now to move it to top
                entries[index].timestamp = now
                sortEntries()
                persistEntries()
                
                logger.info("🔄 [HistoryStore] New message matches history item, moved to top: \(matchingEntry.previewText.prefix(50))")
                return entries
            }
        }
        
        // Not a duplicate - add to history
        let beforeCount = entries.count
        entries.append(entry)
        sortEntries()
        trimIfNeeded()
        persistEntries()
        let afterCount = entries.count
        logger.info("✅ [HistoryStore] Inserted entry: \(entry.previewText.prefix(50)), before: \(beforeCount), after: \(afterCount)")
        return entries
    }

    public func all() -> [ClipboardEntry] {
        // Ensure entries are sorted after loading from persistence
        if !entries.isEmpty {
            sortEntries()
        }
        return entries
    }

    public func entry(withID id: UUID) -> ClipboardEntry? {
        entries.first { $0.id == id }
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persistEntries()
    }

    public func clear() {
        entries.removeAll()
        persistEntries()
    }

    @discardableResult
    public func updatePinState(id: UUID, isPinned: Bool) -> [ClipboardEntry] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries }
        entries[index].isPinned = isPinned
        sortEntries()
        persistEntries()
        return entries
    }

    @discardableResult
    public func updateLimit(_ newLimit: Int) -> [ClipboardEntry] {
        maxEntries = max(1, newLimit)
        trimIfNeeded()
        persistEntries()
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
            // Protect pinned items during trim (like Android)
            let pinnedItems = entries.filter { $0.isPinned }
            let unpinnedItems = entries.filter { !$0.isPinned }
            
            // Keep all pinned items + most recent unpinned items up to limit
            let keepUnpinnedCount = max(0, maxEntries - pinnedItems.count)
            let sortedUnpinned = unpinnedItems.sorted { $0.timestamp > $1.timestamp }
            let keepUnpinned = Array(sortedUnpinned.prefix(keepUnpinnedCount))
            
            entries = pinnedItems + keepUnpinned
            sortEntries() // Re-sort to maintain order
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
    @Published public var plainTextModeEnabled: Bool {
        didSet {
            logger.info("🔧 [ClipboardHistoryViewModel] plainTextModeEnabled changed to: \(plainTextModeEnabled)")
            defaults.set(plainTextModeEnabled, forKey: DefaultsKey.plainTextMode)
            // Verify it was saved
            let saved = defaults.bool(forKey: DefaultsKey.plainTextMode)
            logger.info("🔧 [ClipboardHistoryViewModel] Saved to UserDefaults: \(saved)")
        }
    }
    @Published public private(set) var pairedDevices: [PairedDevice] = []
    @Published public private(set) var encryptionKeySummary: String
    
    // Message queue for sync messages with 1-minute window
    private struct QueuedSyncMessage {
        let entry: ClipboardEntry
        let payload: ClipboardPayload
        let queuedAt: Date
        let targetDeviceId: String
    }
    private var syncMessageQueue: [QueuedSyncMessage] = []
    private var queueProcessingTask: Task<Void, Never>?
    @Published public private(set) var connectionState: ConnectionState = .idle

    private let store: HistoryStore
    public let transportManager: TransportManager?
    private var connectionStateCancellable: AnyCancellable?
    private let defaults: UserDefaults
#if canImport(UserNotifications)
    private let notificationController: ClipboardNotificationScheduling?
#endif
    private var loadTask: Task<Void, Never>?
#if canImport(os)
    private let logger = HypoLogger(category: "transport")
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
            guard let self = self else { return }
            self.logger.info("🔔 [HistoryStore] PairingCompleted notification received!")
            let userInfo = notification.userInfo ?? [:]
            self.logger.info("   Full userInfo: \(userInfo)")
            
            // Write to debug log
            guard let deviceIdString = userInfo["deviceId"] as? String,
                  let deviceName = userInfo["deviceName"] as? String else {
                self.logger.info("⚠️ [HistoryStore] PairingCompleted notification missing required fields")
                self.logger.info("   userInfo keys: \(userInfo.keys)")
                self.logger.info("   deviceId type: \(type(of: userInfo["deviceId"]))")
                self.logger.info("   deviceName type: \(type(of: userInfo["deviceName"]))")
#if canImport(os)
                self.logger.warning("⚠️ PairingCompleted notification missing required fields")
#endif
                return
            }
            
            self.logger.info("📱 [HistoryStore] Processing device: \(deviceName), ID: \(deviceIdString)")
            
            Task { @MainActor in
                await self.handlePairingCompleted(deviceId: deviceIdString, deviceName: deviceName)
            }
        }
        
        // Observe TransportManager's connection state
        if let transportManager = transportManager {
#if canImport(Combine)
            // Set initial state first
            connectionState = transportManager.connectionState
            logger.info("🔌 [ClipboardHistoryViewModel] Initial connection state: \(connectionState)")
            logger.info("🔌 [ClipboardHistoryViewModel] TransportManager connectionState: \(transportManager.connectionState)")
            
            // Observe changes
            connectionStateCancellable = transportManager.connectionStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] newState in
                    guard let self = self else { return }
                    logger.info("🔌 [ClipboardHistoryViewModel] Connection state updated from publisher: \(newState)")
                    self.connectionState = newState
                    logger.info("🔌 [ClipboardHistoryViewModel] Updated self.connectionState to: \(self.connectionState)")
                }
            
            // Also set up a timer to periodically check the state (fallback)
            Task { @MainActor in
                while true {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // Every 2 seconds
                    let currentState = transportManager.connectionState
                    if currentState != connectionState {
                        logger.info("🔌 [ClipboardHistoryViewModel] State mismatch detected! Publisher: \(connectionState), Direct: \(currentState)")
                        connectionState = currentState
                    }
                }
            }
#endif
        } else {
            logger.info("⚠️ [ClipboardHistoryViewModel] No TransportManager provided, connection state will remain idle")
        }
        
        // Listen for connection status changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DeviceConnectionStatusChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            self.logger.info("🔔 [HistoryStore] DeviceConnectionStatusChanged notification received")
            self.logger.info("🔔 [HistoryStore] userInfo: \(notification.userInfo ?? [:])")
            guard let userInfo = notification.userInfo,
                  let deviceId = userInfo["deviceId"] as? String,
                  let isOnline = userInfo["isOnline"] as? Bool else {
                self.logger.info("⚠️ [HistoryStore] Invalid notification userInfo: \(notification.userInfo ?? [:])")
                return
            }
            self.logger.info("🔔 [HistoryStore] Calling updateDeviceOnlineStatus: deviceId=\(deviceId), isOnline=\(isOnline)")
            Task { @MainActor in
                await self.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: isOnline)
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
        logger.info("📝 [HistoryStore] handlePairingCompleted called: \(deviceName) (\(deviceId))")
        
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
        logger.info("✅ [HistoryStore] Device saved! Total paired devices: \(pairedDevices.count)")
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
                logger.info("🔄 [HistoryStore] Reload deduplication: \(beforeCount) → \(afterCount) devices")
            }
            self.pairedDevices = deduplicated
            if let encoded = try? JSONEncoder().encode(deduplicated) {
                defaults.set(encoded, forKey: DefaultsKey.pairedDevices)
            }
        }
    }

    public func start() async {
        // Ensure setHistoryViewModel is called if transportManager is available
        // This handles cases where SwiftUI doesn't call the custom init()
        if let transportManager = transportManager {
            logger.info("🚀 [ClipboardHistoryViewModel] start() called, ensuring setHistoryViewModel")
            transportManager.setHistoryViewModel(self)
        }
        // Reload and deduplicate paired devices on startup
        reloadPairedDevices()
        
        // Initial connection status check on startup
        // (Periodic checks are handled by ConnectionStatusProber)
        await checkActiveConnections()
        
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
        logger.info("\n\(report)")
#else
        logger.info("\(report)")
#endif
    }

    public func add(_ entry: ClipboardEntry) async {
        logger.info("📥 [ClipboardHistoryViewModel] add() called for entry: \(entry.previewText.prefix(50))")
        
        if autoDeleteAfterHours > 0 {
            let expireDate = Date().addingTimeInterval(TimeInterval(autoDeleteAfterHours) * 3600)
            scheduleExpiry(for: entry.id, date: expireDate)
        }
        
        // Insert entry into store (for local entries from ClipboardMonitor)
        // Remote entries are already inserted by IncomingClipboardHandler, but local entries need to be inserted here
        let insertedEntries = await store.insert(entry)
        logger.info("💾 [ClipboardHistoryViewModel] Inserted entry into store: \(insertedEntries.count) total entries")
        
        // Reload all entries from store to get the latest state including any sorting/trimming that happened
        let updated = await store.all()
        logger.info("🔄 [ClipboardHistoryViewModel] Reloading items from store: current=\(self.items.count), store=\(updated.count) entries")
        
        await MainActor.run {
            self.items = updated
            self.latestItem = updated.first
        }
        
        logger.info("✅ [ClipboardHistoryViewModel] items array updated: \(updated.count) entries")
#if canImport(UserNotifications)
        notificationController?.deliverNotification(for: entry)
#endif
        
        // ✅ Auto-sync to paired devices
        await syncToPairedDevices(entry)
    }
    
    private func syncToPairedDevices(_ entry: ClipboardEntry) async {
        guard transportManager != nil else { return }
        
        // ⚠️ CRITICAL: Only forward entries that originated from the local device
        // Skip forwarding if entry came from a remote device (has transportOrigin set)
        // or if originDeviceId doesn't match local device ID
        if entry.transportOrigin != nil {
            logger.info("⏭️ [ClipboardHistoryViewModel] Skipping sync - entry came from remote device (transportOrigin: \(entry.transportOrigin!))")
            return
        }
        
        if entry.originDeviceId != localDeviceId {
            logger.info("⏭️ [ClipboardHistoryViewModel] Skipping sync - entry originated from different device: \(entry.originDeviceId) (local: \(localDeviceId))")
            return
        }
        
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
        
        // Queue messages for all paired devices (best-effort practice - sync regardless of status)
        // If no devices are paired, queue will be empty and nothing will happen
        for device in pairedDevices {
            let queuedMessage = QueuedSyncMessage(
                entry: entry,
                payload: payload,
                queuedAt: Date(),
                targetDeviceId: device.id
            )
            syncMessageQueue.append(queuedMessage)
        }
        
        // Start queue processor if not running
        if queueProcessingTask == nil || queueProcessingTask?.isCancelled == true {
            queueProcessingTask = Task { [weak self] in
                await self?.processSyncQueue()
            }
        }
    }
    
    /// Process the sync message queue, retrying messages until sent or expired (1 minute)
    private func processSyncQueue() async {
        while !Task.isCancelled {
            let now = Date()
            guard let transportManager = transportManager else {
                // If transport manager is not available, wait and retry
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                continue
            }
            
            // Process queue
            var remainingMessages: [QueuedSyncMessage] = []
            for message in syncMessageQueue {
                // Expire messages older than 1 minute
                if now.timeIntervalSince(message.queuedAt) > 60 {
#if canImport(os)
                    logger.info("⏭️ Expired sync message for device \(message.targetDeviceId) (queued \(Int(now.timeIntervalSince(message.queuedAt)))s ago)")
#endif
                    continue // Drop expired message
                }
                
                // Try to send message
                if await trySendMessage(message, transportManager: transportManager) {
                    // Success - message cleared from queue
#if canImport(os)
                    logger.info("✅ Successfully sent queued message to device \(message.targetDeviceId)")
#endif
                    continue
                } else {
                    // Failed - keep in queue for retry
                    remainingMessages.append(message)
                }
            }
            
            syncMessageQueue = remainingMessages
            
            // Wait 5 seconds before next retry
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
    
    /// Attempt to send a queued sync message
    private func trySendMessage(_ message: QueuedSyncMessage, transportManager: TransportManager) async -> Bool {
        do {
        // Get sync engine with transport
        let transport = transportManager.loadTransport()
        let keyProvider = KeychainDeviceKeyProvider()
        let syncEngine = SyncEngine(
            transport: transport,
            keyProvider: keyProvider,
                localDeviceId: deviceIdentity.deviceId.uuidString,
                localPlatform: deviceIdentity.platform
        )
        
        // Ensure transport is connected
        await syncEngine.establishConnection()
        
            // Attempt to send (best-effort - try regardless of device online status)
            try await syncEngine.transmit(entry: message.entry, payload: message.payload, targetDeviceId: message.targetDeviceId)
            
            // Update lastSeen timestamp after successful sync
            if let device = pairedDevices.first(where: { $0.id == message.targetDeviceId }) {
                await updateDeviceLastSeen(deviceId: device.id)
            }
            
            return true // Success
            } catch {
#if canImport(os)
            logger.debug("⏳ Failed to send queued message to \(message.targetDeviceId): \(error.localizedDescription) - will retry")
#endif
            return false // Failed, will retry
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

    // Note: allowsCloudFallback is deprecated - we always dual-send now
    // Keeping the property for backward compatibility but it's no longer used

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
    
    public func updateDeviceOnlineStatus(deviceId: String, isOnline: Bool) async {
        logger.info("🔍 [HistoryStore] updateDeviceOnlineStatus called: deviceId=\(deviceId), isOnline=\(isOnline)")
        logger.info("🔍 [HistoryStore] Current paired devices count: \(pairedDevices.count)")
        for (idx, device) in pairedDevices.enumerated() {
            logger.info("🔍 [HistoryStore] Paired device[\(idx)]: id=\(device.id), name=\(device.name), isOnline=\(device.isOnline)")
        }
        
        guard let index = pairedDevices.firstIndex(where: { $0.id == deviceId }) else {
            logger.info("⚠️ [HistoryStore] Cannot update online status - device not found: \(deviceId)")
            logger.info("⚠️ [HistoryStore] Available device IDs: \(pairedDevices.map { $0.id }.joined(separator: ", "))")
            // Try case-insensitive matching as fallback
            if let caseInsensitiveIndex = pairedDevices.firstIndex(where: { $0.id.lowercased() == deviceId.lowercased() }) {
                logger.info("✅ [HistoryStore] Found device with case-insensitive match, updating...")
                let device = pairedDevices[caseInsensitiveIndex]
                if device.isOnline != isOnline {
                    logger.info("🔄 [HistoryStore] Updating device \(device.name) online status: \(device.isOnline) → \(isOnline)")
                    
                    // Create a new array with the updated device to ensure SwiftUI detects the change
                    var updatedDevices: [PairedDevice] = []
                    for (idx, d) in pairedDevices.enumerated() {
                        if idx == caseInsensitiveIndex {
                            updatedDevices.append(PairedDevice(
                                id: device.id,
                                name: device.name,
                                platform: device.platform,
                                lastSeen: device.lastSeen, // Don't update lastSeen here - only update on actual activity
                                isOnline: isOnline,
                                serviceName: device.serviceName,
                                bonjourHost: device.bonjourHost,
                                bonjourPort: device.bonjourPort,
                                fingerprint: device.fingerprint
                            ))
                        } else {
                            updatedDevices.append(d)
                        }
                    }
                    
                    // Update the ViewModel's @Published property by replacing the entire array
                    // Since we're already @MainActor, update directly
                    self.pairedDevices = updatedDevices
                    
                    // Force UI update by triggering objectWillChange BEFORE the @Published change
                    objectWillChange.send()
                    
                    logger.info("🔄 [HistoryStore] Updated pairedDevices array (count: \(updatedDevices.count)) and triggered objectWillChange.send() (case-insensitive)")
                    
                    // Verify the update immediately
                    if let updatedDevice = pairedDevices.first(where: { $0.id == device.id }) {
                        logger.info("✅ [HistoryStore] Verified update: device \(device.name) isOnline=\(updatedDevice.isOnline) in array")
                    }
                    
                    persistPairedDevices()
                    
                    logger.info("✅ [HistoryStore] Device \(device.name) status updated (case-insensitive) and persisted: isOnline=\(isOnline)")
                }
                return
            }
            return
        }
        let device = pairedDevices[index]
        if device.isOnline != isOnline {
            logger.info("🔄 [HistoryStore] Updating device \(device.name) online status: \(device.isOnline) → \(isOnline)")
            
            // Create a new array with the updated device to ensure SwiftUI detects the change
            // This replaces the entire array, which triggers @Published change detection
            var updatedDevices: [PairedDevice] = []
            for (idx, d) in pairedDevices.enumerated() {
                if idx == index {
                    updatedDevices.append(PairedDevice(
                        id: device.id,
                        name: device.name,
                        platform: device.platform,
                        lastSeen: device.lastSeen, // Don't update lastSeen here - only update on actual activity
                        isOnline: isOnline,
                        serviceName: device.serviceName,
                        bonjourHost: device.bonjourHost,
                        bonjourPort: device.bonjourPort,
                        fingerprint: device.fingerprint
                    ))
                } else {
                    updatedDevices.append(d)
                }
            }
            
            // Update the ViewModel's @Published property by replacing the entire array
            // This triggers SwiftUI's change detection
            // Since we're already @MainActor, update directly
            self.pairedDevices = updatedDevices
            
            // Force UI update by triggering objectWillChange BEFORE the @Published change
            // This ensures SwiftUI sees the change
            objectWillChange.send()
            
            logger.info("🔄 [HistoryStore] Updated pairedDevices array (count: \(updatedDevices.count)) and triggered objectWillChange.send()")
            
            // Verify the update immediately
            if let updatedDevice = pairedDevices.first(where: { $0.id == device.id }) {
                logger.info("✅ [HistoryStore] Verified update: device \(device.name) isOnline=\(updatedDevice.isOnline) in array")
            } else {
                logger.error("❌ [HistoryStore] ERROR: Device \(device.name) not found in updated array!")
            }
            
            // Persist to UserDefaults
            persistPairedDevices()
            
            logger.info("✅ [HistoryStore] Device \(device.name) status updated and persisted: isOnline=\(isOnline) (array replaced, count: \(updatedDevices.count))")
        } else {
            logger.info("ℹ️ [HistoryStore] Device \(device.name) online status unchanged: \(isOnline)")
        }
    }
    
    /// Check active WebSocket connections and update device online status
    private func checkActiveConnections() async {
        // Connection status is managed via DeviceConnectionStatusChanged notifications
        // which are posted when connections are established/closed.
        // On startup, we mark all devices as offline initially, and they'll be marked
        // online when connections are actually established.
        logger.info("🔍 [HistoryStore] Initializing device status - connections will update via notifications")
        
        // Mark all devices as offline initially (they'll be updated when connections are established)
        var updated = false
        for (index, device) in pairedDevices.enumerated() {
            if device.isOnline {
                logger.info("🔄 [HistoryStore] Marking device \(device.name) as offline on startup (will update when connection established)")
            pairedDevices[index] = PairedDevice(
                id: device.id,
                name: device.name,
                platform: device.platform,
                    lastSeen: device.lastSeen,
                    isOnline: false
                )
                updated = true
            }
        }
        if updated {
            persistPairedDevices()
        }
    }
    
    /// Update lastSeen timestamp for a device (public method for external callers)
    public func updateDeviceLastSeen(deviceId: String) async {
        guard let index = pairedDevices.firstIndex(where: { $0.id == deviceId }) else {
            logger.info("⚠️ [HistoryStore] Cannot update lastSeen - device not found: \(deviceId)")
            return
        }
        let device = pairedDevices[index]
        let now = Date()
        // Only update if it's been more than 1 second since last update (avoid excessive updates)
        if now.timeIntervalSince(device.lastSeen) > 1.0 {
            logger.info("🔄 [HistoryStore] Updating device \(device.name) lastSeen: \(device.lastSeen) → \(now)")
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
        deviceIdentity.deviceId.uuidString  // UUID string (pure UUID, no prefix)
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
        // Persist the current pairedDevices array to UserDefaults
        // Note: We don't modify pairedDevices here to avoid overwriting recent updates
        // Deduplication is handled when loading from UserDefaults, not when persisting
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
        let logger = HypoLogger(category: "ClipboardHistoryViewModel")
        let localId = deviceIdentity.deviceId.uuidString
        let isLocal = entry.originDeviceId == localId
        logger.info("📋 [ClipboardHistoryViewModel] clipboardMonitor didCapture: \(entry.previewText.prefix(50)), originDeviceId: \(entry.originDeviceId), localDeviceId: \(localId), isLocal: \(isLocal), transportOrigin: \(entry.transportOrigin?.rawValue ?? "nil")")
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

    // Bonjour/discovery information
    public let serviceName: String?
    public let bonjourHost: String?
    public let bonjourPort: Int?
    public let fingerprint: String?
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        platform: String,
        lastSeen: Date,
        isOnline: Bool,
        serviceName: String? = nil,
        bonjourHost: String? = nil,
        bonjourPort: Int? = nil,
        fingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSeen = lastSeen
        self.isOnline = isOnline
        self.serviceName = serviceName
        self.bonjourHost = bonjourHost
        self.bonjourPort = bonjourPort
        self.fingerprint = fingerprint
    }
    
    /// Create a PairedDevice from a DiscoveredPeer
    public init(from peer: DiscoveredPeer, name: String, platform: String) {
        self.id = peer.endpoint.metadata["device_id"] ?? peer.serviceName
        self.name = name
        self.platform = platform
        self.lastSeen = peer.lastSeen
        self.isOnline = true
        self.serviceName = peer.serviceName
        self.bonjourHost = peer.endpoint.host
        self.bonjourPort = peer.endpoint.port
        self.fingerprint = peer.endpoint.fingerprint
    }
    
    /// Update with discovery information from a DiscoveredPeer
    public func updating(from peer: DiscoveredPeer) -> PairedDevice {
        PairedDevice(
            id: self.id,
            name: self.name,
            platform: self.platform,
            lastSeen: max(self.lastSeen, peer.lastSeen),
            isOnline: self.isOnline,
            serviceName: peer.serviceName,
            bonjourHost: peer.endpoint.host,
            bonjourPort: peer.endpoint.port,
            fingerprint: peer.endpoint.fingerprint
        )
    }
}
