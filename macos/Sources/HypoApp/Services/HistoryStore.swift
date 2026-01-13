import Foundation
import CryptoKit

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
#if canImport(UserNotifications)
import UserNotifications
#endif

// UserDefaults is thread-safe for reading/writing, safe to mark as Sendable
// Sendable conformance for SDK type – UserDefaults is thread-safe for reads/writes
extension UserDefaults: @unchecked @retroactive Sendable {}

public actor HistoryStore {
    private let logger = HypoLogger(category: "HistoryStore")
    private var entries: [ClipboardEntry] = []
    private var maxEntries: Int
    private let defaults: UserDefaults
    private static let entriesKey = "com.hypo.clipboard.history_entries"
    private static let fileStorageMigrationKey = "com.hypo.clipboard.file_storage_migration_v2"

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
        
        // Migration: If upgrading to v2 (file storage), clear old history to prevent issues
        if !defaults.bool(forKey: Self.fileStorageMigrationKey) {
            logger.warning("⚠️ [HistoryStore] Upgrading to file-based storage. Clearing old history.")
            #if canImport(os)
            let logger = HypoLogger(category: "history")
            logger.info("🧹 Clearing old history for file storage migration")
            #endif
            self.entries.removeAll()
            // Clear UserDefaults
            defaults.removeObject(forKey: Self.entriesKey)
            // Initialize storage manager (clears files too if needed, though usually empty on first run)
            StorageManager.shared.clearAll()
            
            defaults.set(true, forKey: Self.fileStorageMigrationKey)
        }
    }
    
    private func persistEntries() {
        let encoder = JSONEncoder()
        // Critical: Skip large data blobs when saving to UserDefaults
        encoder.userInfo[.skipLargeData] = true
        
        if let encoded = try? encoder.encode(self.entries) {
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
    public func insert(_ entry: ClipboardEntry) -> (entries: [ClipboardEntry], duplicate: ClipboardEntry?) {
        let now = Date()
        
        // Simplified duplicate detection (no time windows):
        // 1. If new message matches something in history:
        //    - Local entry → move to top (even if it's the latest entry)
        //    - Remote entry → discard duplicate to preserve chronological order
        // 2. Otherwise → add new entry
        
        // Check if matches something in history (including the latest entry)
        if let matchingEntry = entries.first(where: { existingEntry in
            entry.matchesContent(existingEntry)
        }) {
            // Found matching entry in history
            if let index = entries.firstIndex(where: { $0.id == matchingEntry.id }) {
                // Move matching entry to top regardless of whether incoming entry is local or received
                // This ensures that when Android clicks an item (which sends it back to macOS),
                // the existing macOS item moves to top, reflecting the user's active use of the item
                // Preserve pin state - if it was pinned, keep it pinned (it will move to top of pinned items)
                // If it wasn't pinned, keep it unpinned (it will move to top of unpinned items)
                entries[index].timestamp = now
                // Don't change isPinned - preserve user's pin preference
                sortEntries()
                persistEntries()
                if entry.transportOrigin == nil {
                    logger.debug("🔄 [HistoryStore] Local entry matches history item, moved to top (pinned: \(entries[index].isPinned)): \(matchingEntry.previewText.prefix(50))")
                } else {
                    logger.debug("🔄 [HistoryStore] Received entry matches history item, moved existing item to top (pinned: \(entries[index].isPinned)): \(matchingEntry.previewText.prefix(50))")
                }
                return (entries, matchingEntry)
            }
        }
        
        // Not a duplicate - add to history
        let beforeCount = entries.count
        entries.append(entry)
        sortEntries()
        trimIfNeeded()
        persistEntries()
        let afterCount = entries.count
        logger.debug("✅ [HistoryStore] Inserted entry: \(entry.previewText.prefix(50)), before: \(beforeCount), after: \(afterCount)")
        return (entries, nil)
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
        guard let index = entries.firstIndex(where: { $0.id == id }) else { 
            logger.warning("⚠️ [HistoryStore] Cannot find entry with id \(id) to update pin state")
            return entries 
        }
        // Allow unpinning any item, including the first one
        entries[index].isPinned = isPinned
        sortEntries()
        persistEntries()
        logger.debug("📌 [HistoryStore] Updated pin state for entry \(id): isPinned=\(isPinned)")
        return entries
    }

    @discardableResult
    public func togglePin(id: UUID) -> [ClipboardEntry] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            logger.warning("⚠️ [HistoryStore] Cannot find entry with id \(id) to toggle pin state")
            return entries
        }
        entries[index].isPinned.toggle()
        sortEntries()
        persistEntries()
        logger.debug("📌 [HistoryStore] Toggled pin state for entry \(id): isPinned=\(entries[index].isPinned)")
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
            // Standard sorting: pinned items first, then by timestamp (newest first)
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
    @Published public var allowsCloudFallback: Bool
    @Published public var appearancePreference: AppearancePreference
    @Published public var autoDeleteAfterHours: Int
    @Published public var plainTextModeEnabled: Bool {
        didSet {
            defaults.set(plainTextModeEnabled, forKey: DefaultsKey.plainTextMode)
        }
    }
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    // Message queue for sync messages with 1-minute window
    private struct QueuedSyncMessage {
        let entry: ClipboardEntry
        let payload: ClipboardPayload
        let queuedAt: Date
        let targetDeviceId: String
    }
    private var syncMessageQueue: [QueuedSyncMessage] = []
    private var queueProcessingTask: Task<Void, Never>?
    private var queueProcessingContinuation: CheckedContinuation<Void, Never>?

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
        self.allowsCloudFallback = defaults.object(forKey: DefaultsKey.allowsCloudFallback) as? Bool ?? true
        self.autoDeleteAfterHours = defaults.object(forKey: DefaultsKey.autoDeleteHours) as? Int ?? 0
        self.plainTextModeEnabled = defaults.object(forKey: DefaultsKey.plainTextMode) as? Bool ?? false
        if let rawAppearance = defaults.string(forKey: DefaultsKey.appearance),
           let appearance = AppearancePreference(rawValue: rawAppearance) {
            self.appearancePreference = appearance
        } else {
            self.appearancePreference = .system
        }
#if canImport(UserNotifications)
        self.notificationController = ClipboardNotificationController()
        if let controller = self.notificationController {
            controller.configure(handler: self)
            logger.info("✅ Notification controller initialized successfully")
        } else {
            logger.warning("⚠️ Notification controller failed to initialize (may be running from .build directory, not .app bundle)")
        }
#endif
        if let transportManager = transportManager {
            self.connectionState = transportManager.connectionState
            self.connectionStateCancellable = transportManager.connectionStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.connectionState = state
                    // Wake up queue when we connect
                    if state != .disconnected {
                        self?.triggerSyncQueueProcessing()
                    }
                }
        }
    }
    
    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    

    public func start() async {
        // Ensure setHistoryViewModel is called if transportManager is available
        // This handles cases where SwiftUI doesn't call the custom init()
        if let transportManager = transportManager {
            logger.info("🚀 [ClipboardHistoryViewModel] start() called, ensuring setHistoryViewModel")
            transportManager.setHistoryViewModel(self)
        }
        
        // Device online status is managed by ConnectionStatusProber
        // No need to check active connections here - ConnectionStatusProber will update status
        
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
        
        if autoDeleteAfterHours > 0 {
            let expireDate = Date().addingTimeInterval(TimeInterval(autoDeleteAfterHours) * 3600)
            scheduleExpiry(for: entry.id, date: expireDate)
        }
        
        // Insert entry into store (for local entries from ClipboardMonitor)
        // Remote entries are already inserted by IncomingClipboardHandler, but local entries need to be inserted here
        // We get back the updated list and potentially a duplicate entry if one existed
        let (insertedEntries, duplicate) = await store.insert(entry)
        logger.debug("💾 [ClipboardHistoryViewModel] Inserted entry into store: \(insertedEntries.count) total entries")
        
        // Reload all entries from store to get the latest state including any sorting/trimming that happened
        let updated = await store.all()
        logger.debug("🔄 [ClipboardHistoryViewModel] Reloading items from store: current=\(self.items.count), store=\(updated.count) entries")
        
        await MainActor.run {
            self.items = updated
            self.latestItem = updated.first
        }
        
        logger.debug("✅ [ClipboardHistoryViewModel] items array updated: \(updated.count) entries")
        
        // Only show notifications for remote clipboard items (not local copies)
        let localId = deviceIdentity.deviceId.uuidString.lowercased()
        let isRemote = entry.deviceId.lowercased() != localId
        
        // Determine if we should notify
        // 1. Must be a remote item
        // 2. Must NOT be an echo of a local item (originated from here, sent back by peer)
        var shouldNotify = isRemote
        
        if isRemote, let duplicate = duplicate {
            // Check if the duplicate (existing item) was local
            // If we already have this content and it originated locally, this is an echo
            if duplicate.deviceId.lowercased() == localId {
                logger.debug("📢 [ClipboardHistoryViewModel] Duplicate of local item detected (echo), suppressing notification")
                shouldNotify = false
            }
        }
        
        if shouldNotify {
            logger.debug("📢 [ClipboardHistoryViewModel] Remote clipboard item detected, showing notification")
#if canImport(UserNotifications)
            notificationController?.deliverNotification(for: entry)
#endif
        } else {
            logger.debug("📢 [ClipboardHistoryViewModel] Local clipboard item or echo, skipping notification")
        }
        
        // ✅ Auto-sync to paired devices
        await syncToPairedDevices(entry)
    }
    
    private func syncToPairedDevices(_ entry: ClipboardEntry) async {

        guard transportManager != nil else {
#if canImport(os)
            logger.warning("⏭️ [HistoryStore] Skipping sync - transportManager is nil")
#endif
            return
        }
        
        // ⚠️ CRITICAL: Only forward entries that originated from the local device
        // Skip forwarding if entry came from a remote device (has transportOrigin set)
        // or if deviceId doesn't match local device ID
        if entry.transportOrigin != nil {
#if canImport(os)
            logger.info("⏭️ [ClipboardHistoryViewModel] Skipping sync - entry came from remote device (transportOrigin: \(entry.transportOrigin!))")
#endif
            return
        }
        
        // Compare using lowercase normalization
        if entry.deviceId != localDeviceId.lowercased() {
#if canImport(os)
            logger.info("⏭️ [ClipboardHistoryViewModel] Skipping sync - entry originated from different device: \(entry.deviceId) (local: \(localDeviceId.lowercased()))")
#endif
            return
        }
        
#if canImport(os)
        logger.debug("✅ [HistoryStore] Entry is local, syncing to \(transportManager?.pairedDevices.count ?? 0) device(s)")
#endif
        
        // Convert clipboard entry to payload
        let payload: ClipboardPayload
        switch entry.content {
        case .text(let text):
            let data = Data(text.utf8)
            let digest = SHA256.hash(data: data)
            let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
            
            payload = ClipboardPayload(
                contentType: .text,
                data: data,
                metadata: [
                    "device_id": entry.deviceId,
                    "device_name": entry.originDeviceName ?? "",
                    "hash": hashString
                ]
            )
        case .link(let url):
            let data = Data(url.absoluteString.utf8)
            let digest = SHA256.hash(data: data)
            let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
            
            payload = ClipboardPayload(
                contentType: .link,
                data: data,
                metadata: [
                    "device_id": entry.deviceId,
                    "device_name": entry.originDeviceName ?? "",
                    "hash": hashString
                ]
            )
        case .image(let metadata):
            // Extract image data from ImageMetadata
            // For images from pasteboard, data is available immediately
            // For image files stored as files, they'll be handled in the .file case
            guard let imageData = metadata.data else {
#if canImport(os)
                logger.warning("⚠️ [HistoryStore] Image entry has no data, skipping sync")
#endif
                return
            }
            
            // Check size limit
            if imageData.count > SizeConstants.maxAttachmentBytes {
#if canImport(os)
                logger.warning("⚠️ [HistoryStore] Image too large: \(imageData.count.formattedAsKB) (limit: \(SizeConstants.maxAttachmentBytes.formattedAsKB)), skipping sync")
#endif
                // Show notification to user
                await MainActor.run {
                    let sizeMB = Double(imageData.count) / (1024.0 * 1024.0)
                    let maxMB = Double(SizeConstants.maxAttachmentBytes) / (1024.0 * 1024.0)
                    showSizeLimitExceededNotification(itemType: "Image", sizeMB: sizeMB, maxMB: maxMB)
                }
                // Show notification to user
                await MainActor.run {
                    let sizeMB = Double(imageData.count) / (1024.0 * 1024.0)
                    let maxMB = Double(SizeConstants.maxAttachmentBytes) / (1024.0 * 1024.0)
                    showSizeLimitExceededNotification(itemType: "Image", sizeMB: sizeMB, maxMB: maxMB)
                }
                return
            }
            
#if canImport(os)
            logger.debug("🖼️ [HistoryStore] Preparing image sync: \(imageData.count.formattedAsKB)")
#endif
            
            // Calculate SHA-256 hash of image data
            let digest = SHA256.hash(data: imageData)
            let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
            
            var imageMetadata: [String: String] = [
                "device_id": entry.deviceId,
                "device_name": entry.originDeviceName ?? "",
                "hash": hashString
            ]
            if let altText = metadata.altText {
                imageMetadata["file_name"] = altText
            }
            imageMetadata["format"] = metadata.format
            imageMetadata["width"] = "\(Int(metadata.pixelSize.width))"
            imageMetadata["height"] = "\(Int(metadata.pixelSize.height))"
            
            payload = ClipboardPayload(
                contentType: .image,
                data: imageData,
                metadata: imageMetadata
            )
        case .file(let metadata):
            // Extract file data for sync.
            // Prefer base64 (for remote-origin entries); fall back to local file URL
            // for entries that originated on this device where we only stored a pointer.
            // Load file content async to avoid blocking on iCloud files
            let fileData: Data
            if let base64String = metadata.base64,
               let decoded = Data(base64Encoded: base64String) {
                fileData = decoded
            } else if let url = metadata.url {
                // Load file content async to avoid blocking
                do {
                    // Use async file reading with timeout to prevent hanging on iCloud files
                    fileData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                        Task.detached(priority: .userInitiated) {
                            do {
                                // Use mappedIfSafe for better performance with large files
                                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                                continuation.resume(returning: data)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                } catch {
#if canImport(os)
                    logger.warning("⚠️ [HistoryStore] Failed to load file from URL: \(error.localizedDescription), skipping sync")
#endif
                    return
                }
            } else {
#if canImport(os)
                logger.warning("⚠️ [HistoryStore] File entry has no data or URL, skipping sync")
#endif
                return
            }
            
            // Check size limit
            if fileData.count > SizeConstants.maxAttachmentBytes {
#if canImport(os)
                logger.warning("⚠️ [HistoryStore] File too large: \(fileData.count.formattedAsKB) (limit: \(SizeConstants.maxAttachmentBytes.formattedAsKB)), skipping sync")
#endif
                // Show notification to user
                await MainActor.run {
                    let sizeMB = Double(fileData.count) / (1024.0 * 1024.0)
                    let maxMB = Double(SizeConstants.maxAttachmentBytes) / (1024.0 * 1024.0)
                    let fileName = metadata.fileName
                    showSizeLimitExceededNotification(itemType: fileName, sizeMB: sizeMB, maxMB: maxMB)
                }
                return
            }
            
            // Calculate SHA-256 hash of file data for duplicate detection
            let digest = SHA256.hash(data: fileData)
            let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
            
            let fileMetadataDict: [String: String] = [
                "device_id": entry.deviceId,
                "device_name": entry.originDeviceName ?? "",
                "file_name": metadata.fileName,
                "uti": metadata.uti,
                "hash": hashString,
                "size": "\(fileData.count)"
            ]
            
            payload = ClipboardPayload(
                contentType: .file,
                data: fileData,
                metadata: fileMetadataDict
            )
        }
        
        // Queue messages for all paired devices that have encryption keys
        // Send to all devices regardless of online status - relay server can queue messages
        // and deliver them when devices come online
        let keyProvider = KeychainDeviceKeyProvider()
        var devicesWithKeys: [PairedDevice] = []
        var devicesWithoutKeys: [PairedDevice] = []
        
        let devices = transportManager?.pairedDevices ?? []
        for device in devices {
            if keyProvider.hasKey(for: device.id) {
                devicesWithKeys.append(device)
            } else {
                devicesWithoutKeys.append(device)
            }
        }
        
#if canImport(os)
        logger.info("📤 [HistoryStore] Queuing for \(devicesWithKeys.count) device(s) with keys (including offline devices - relay will queue)")
        if devices.isEmpty {
            logger.warning("⚠️ [HistoryStore] No paired devices found! Clipboard sync will not be sent to any peers.")
            logger.warning("⚠️ [HistoryStore] To sync clipboard, you need to pair with at least one device first.")
        }
        if !devicesWithoutKeys.isEmpty {
            for device in devicesWithoutKeys {
                logger.warning("⏭️ [HistoryStore] Skipping device \(device.name) (id: \(device.id.prefix(8))...) - no encryption key found. Device may need to be re-paired.")
            }
        }
        // Log offline devices but still send to them
        let offlineDevices = devicesWithKeys.filter { !$0.isOnline }
        if !offlineDevices.isEmpty {
            for device in offlineDevices {
                logger.info("ℹ️ [HistoryStore] Device \(device.name) (id: \(device.id.prefix(8))...) is offline, but will queue message - relay will deliver when device comes online")
            }
        }
#endif
        
        // Queue a separate message for each device with a key (including offline devices)
        // Each device gets its own message, so failures for one device don't affect others
        // Relay server can queue messages for offline devices and deliver when they reconnect
        for device in devicesWithKeys {
#if canImport(os)
#endif
            let queuedMessage = QueuedSyncMessage(
                entry: entry,
                payload: payload,
                queuedAt: Date(),
                targetDeviceId: device.id
            )
            syncMessageQueue.append(queuedMessage)
        }
        
        // Trigger immediate queue processing (event-driven)
        triggerSyncQueueProcessing()
    }
    
    /// Trigger sync queue processing (event-driven)
    private func triggerSyncQueueProcessing() {
        logger.debug("🔄 [HistoryStore] triggerSyncQueueProcessing: queue=\(syncMessageQueue.count), state=\(String(describing: transportManager?.connectionState))")
        // Resume continuation if waiting
        if queueProcessingContinuation != nil {
#if canImport(os)
            logger.debug("🔄 [HistoryStore] Resuming queue processing")
#endif
            queueProcessingContinuation?.resume()
            queueProcessingContinuation = nil
        }
        
        // Start queue processor if not running
        if queueProcessingTask == nil || queueProcessingTask?.isCancelled == true {
#if canImport(os)
            logger.debug("🔄 [HistoryStore] Starting queue processing")
#endif
            queueProcessingTask = Task { [weak self] in
                await self?.processSyncQueue()
            }
        } else {
#if canImport(os)
            logger.debug("🔄 [HistoryStore] Queue processing already running")
#endif
        }
    }
    
    /// Process the sync message queue (event-driven: triggered when connection available or message queued)
    private func processSyncQueue() async {
#if canImport(os)
        logger.debug("🔄 [HistoryStore] processSyncQueue started: queue=\(syncMessageQueue.count)")
#else
        // No-op
#endif
        // When this task finishes (normal exit or cancellation), allow a new processor to be started
        defer {
            queueProcessingTask = nil
        }
        while !Task.isCancelled {
            let now = Date()
            guard let transportManager = transportManager else {
#if canImport(os)
                logger.warning("⚠️ [HistoryStore] processSyncQueue() waiting: transportManager is nil")
#endif
                // If transport manager is not available, wait for event (connection available or message queued)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { @MainActor [weak self] in
                        self?.queueProcessingContinuation = continuation
                    }
                }
                continue
            }
            
#if canImport(os)
            logger.debug("🔄 [HistoryStore] Processing queue: \(syncMessageQueue.count) messages")
#endif
            // Process queue - send to all devices independently
            // Each message targets a specific device, so failures for one device don't block others
            var remainingMessages: [QueuedSyncMessage] = []
            var hasMessagesToRetry = false
            var successCount = 0
            var failureCount = 0
            
            for message in syncMessageQueue {
                // Expire messages older than 1 minute
                if now.timeIntervalSince(message.queuedAt) > 60 {
#if canImport(os)
                    logger.debug("⏭️ [HistoryStore] Expired sync message for device \(message.targetDeviceId.prefix(8))")
#endif
                    continue // Drop expired message
                }
                
                // Try to send message to this specific device
                // Note: Each device is processed independently - failure for one doesn't affect others
                let sendResult = await trySendMessage(message, transportManager: transportManager)
                if sendResult {
                    // Success - message cleared from queue
                    successCount += 1

                    continue
                } else {
                    // Failed - keep in queue for retry
                    failureCount += 1
#if canImport(os)
                    logger.warning("⚠️ [HistoryStore] Failed to send message to \(message.targetDeviceId), keeping in queue for retry")
#endif
                    remainingMessages.append(message)
                    hasMessagesToRetry = true
                }
            }
            
#if canImport(os)
            if successCount > 0 || failureCount > 0 {
                logger.debug("📊 [HistoryStore] Queue summary: \(successCount) succeeded, \(failureCount) failed")
            }
#endif
            
            syncMessageQueue = remainingMessages
            
#if canImport(os)
            logger.debug("🔄 [HistoryStore] Queue processing completed: retry=\(hasMessagesToRetry), remaining=\(syncMessageQueue.count)")
#endif
            
            if hasMessagesToRetry && (transportManager.connectionState != .disconnected) {
                // If we have messages to retry and connection is available, wait for next event
                // (connection state change or new message queued) instead of polling
#if canImport(os)
                logger.debug("🔄 [HistoryStore] processSyncQueue waiting for event")
#endif
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { @MainActor [weak self] in
                        self?.queueProcessingContinuation = continuation
                    }
                }
#if canImport(os)
                logger.debug("🔄 [HistoryStore] processSyncQueue resumed")
#endif
                // Continue loop to process queue again
                continue
            } else if hasMessagesToRetry {
                // Connection not available, wait for connection state change (event-driven)
#if canImport(os)
                logger.debug("🔄 [HistoryStore] processSyncQueue waiting for connection")
#endif
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { @MainActor [weak self] in
                        self?.queueProcessingContinuation = continuation
                    }
                }
#if canImport(os)
                logger.debug("🔄 [HistoryStore] processSyncQueue resumed after connection")
#endif
                // Continue loop to process queue again
                continue
            } else {
                // No messages to process, exit (will restart when new message is queued)
#if canImport(os)
                logger.debug("🔄 [HistoryStore] processSyncQueue exiting")
#endif
                return
            }
        }
    }
    
    /// Attempt to send a queued sync message
    private func trySendMessage(_ message: QueuedSyncMessage, transportManager: TransportManager) async -> Bool {
        do {
        // Get sync engine with transport
        let transport = transportManager.loadTransport()

        let keyProvider = KeychainDeviceKeyProvider()
        let cryptoService = CryptoService()
        
        // If transport is DualSyncTransport, configure it with crypto service and key provider
        // so it can create separate envelopes with unique nonces for LAN and cloud
        if let dualTransport = transport as? DualSyncTransport {
            dualTransport.configure(cryptoService: cryptoService, keyProvider: keyProvider)
        }
        
        let syncEngine = SyncEngine(
            transport: transport,
            cryptoService: cryptoService,
            keyProvider: keyProvider,
                localDeviceId: deviceIdentity.deviceId.uuidString,
                localPlatform: deviceIdentity.platform
        )
        
        // Ensure transport is connected

        await syncEngine.establishConnection()

        
        // Attempt to send (best-effort - try regardless of device online status)
        let payloadSize = message.payload.data.count
        let contentType = message.payload.contentType.rawValue
#if canImport(os)
        logger.debug("📤 [HistoryStore] Sending \(contentType) (\(payloadSize.formattedAsKB)) to \(message.targetDeviceId.prefix(8))")
#endif
        try await syncEngine.transmit(entry: message.entry, payload: message.payload, targetDeviceId: message.targetDeviceId)
        

            // Update lastSeen timestamp after successful sync
            if let device = transportManager.pairedDevices.first(where: { $0.id == message.targetDeviceId }) {
                transportManager.updatePairedDeviceLastSeen(device.id, lastSeen: Date())
            }
            
            return true // Success
            } catch {
#if canImport(os)
            logger.error("❌ [HistoryStore] Failed to send queued message to \(message.targetDeviceId): \(error.localizedDescription)")
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
        logger.debug("📌 [ClipboardHistoryViewModel] togglePin called for entry: \(entry.id), current isPinned: \(entry.isPinned)")
        Task {
            logger.debug("📌 [ClipboardHistoryViewModel] Requesting toggle pin for: \(entry.id)")
            let updated = await store.togglePin(id: entry.id)
            await MainActor.run {
                self.items = updated
                self.latestItem = updated.first
                logger.debug("📌 [ClipboardHistoryViewModel] Pin state updated. First item isPinned: \(updated.first?.isPinned ?? false)")
            }
        }
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

    
    
    
    /// Check active WebSocket connections and update device online status
    
    /// Update lastSeen timestamp for a device (public method for external callers)


    public func makeRemotePairingViewModel() -> RemotePairingViewModel {
        RemotePairingViewModel(identity: deviceIdentity, onDevicePaired: { [weak transportManager] device in
            transportManager?.registerPairedDevice(device)
        })
    }
    
    #if canImport(AppKit)
    /// Returns the local device ID for comparing entry origins
    public var localDeviceId: String {
        deviceIdentity.deviceId.uuidString  // UUID string (pure UUID, no prefix)
    }
    #endif

    public func copyToPasteboard(_ entry: ClipboardEntry) {
        #if canImport(AppKit)
        // Size check: prevent copying very large items (50MB limit for copying)
        let MAX_COPY_SIZE_BYTES = SizeConstants.maxCopySizeBytes
        let itemSize: Int
        switch entry.content {
        case .text(let value):
            itemSize = value.utf8.count
        case .link:
            itemSize = 0 // Links are small
        case .image(let metadata):
            itemSize = metadata.data?.count ?? 0
        case .file(let metadata):
            itemSize = metadata.byteSize
        }
        
        if itemSize > MAX_COPY_SIZE_BYTES {
            let sizeMB = Double(itemSize) / (1024.0 * 1024.0)
            let limitMB = Double(MAX_COPY_SIZE_BYTES) / (1024.0 * 1024.0)
            logger.warning("⚠️ Item too large to copy: \(String(format: "%.1f", sizeMB)) MB (limit: \(String(format: "%.0f", limitMB)) MB)")
            // Show notification
            Task {
                let itemType: String
                switch entry.content {
                case .image:
                    itemType = "Image"
                case .file:
                    itemType = "File"
                default:
                    itemType = "Item"
                }
                await showSizeLimitNotification(itemType: itemType, sizeMB: sizeMB, limitMB: limitMB)
            }
            return
        }
        
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
            // For files, we need to create a temp file if we only have base64 data
            if let url = metadata.url {
                // File URL exists, use it directly
                pasteboard.writeObjects([url as NSURL])
            } else if let base64 = metadata.base64, let data = Data(base64Encoded: base64) {
                // Create temp file from base64 data
                let tempDir = FileManager.default.temporaryDirectory
                let fileExtension = (metadata.fileName as NSString).pathExtension
                let baseFileName = (metadata.fileName as NSString).deletingPathExtension
                let uniqueFileName = "hypo_\(UUID().uuidString)_\(fileExtension.isEmpty ? baseFileName : "\(baseFileName).\(fileExtension)")"
                let tempURL = tempDir.appendingPathComponent(uniqueFileName)
                
                do {
                    try data.write(to: tempURL)
                    // Register temp file for automatic cleanup
                    TempFileManager.shared.registerTempFile(tempURL)
                    pasteboard.writeObjects([tempURL as NSURL])
                    logger.info("✅ Copied file to clipboard: \(metadata.fileName) (\(data.count.formattedAsKB))")
                } catch {
                    logger.error("❌ Failed to create temp file for copying: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }
    
    private func showSizeLimitNotification(itemType: String, sizeMB: Double, limitMB: Double) async {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Item Too Large"
        content.body = String(format: "Item (%.1f MB) exceeds the maximum copy limit of %.0f MB. Please use a smaller %@.", sizeMB, limitMB, itemType.lowercased())
        content.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
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


}

#if canImport(AppKit)
extension ClipboardHistoryViewModel: ClipboardMonitorDelegate {
    nonisolated public func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry) {
        let logger = HypoLogger(category: "ClipboardHistoryViewModel")
        Task { @MainActor in
            let localId = deviceIdentity.deviceId.uuidString.lowercased()
            let isLocal = entry.deviceId == localId
            logger.info("📋 [ClipboardHistoryViewModel] clipboardMonitor didCapture: \(entry.previewText.prefix(50)), deviceId: \(entry.deviceId), localDeviceId: \(localId), isLocal: \(isLocal), transportOrigin: \(entry.transportOrigin?.rawValue ?? "nil")")
            await self.add(entry)
        }
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

    public func handleNotificationClick(for id: UUID) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowHistoryPopup"),
                object: nil,
                userInfo: ["itemId": id]
            )
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
    
    @MainActor
    private func showSizeLimitExceededNotification(itemType: String, sizeMB: Double, maxMB: Double) {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Item Too Large"
        content.body = String(format: "\"%@\" (%.1f MB) exceeds the maximum size limit of %.0f MB", itemType, sizeMB, maxMB)
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Show immediately
        )
        
        let logger = self.logger // Capture logger explicitly
        center.add(request) { error in
            if let error = error {
                Task { @MainActor in
                    logger.error("❌ Failed to show size limit notification: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }
}

#endif
