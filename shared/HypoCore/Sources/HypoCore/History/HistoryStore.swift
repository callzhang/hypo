import Foundation

// UserDefaults is thread-safe for reading/writing, safe to mark as Sendable
// Sendable conformance for SDK type – UserDefaults is thread-safe for reads/writes
extension UserDefaults: @retroactive @unchecked Sendable {}

public actor HistoryStore {
    private let logger = HypoLogger(category: "HistoryStore")
    private var entries: [ClipboardEntry] = []
    private var maxEntries: Int
    private let persistence: HistoryPersistence
    private static let entriesKey = "com.hypo.clipboard.history_entries"
    private static let fileStorageMigrationKey = "com.hypo.clipboard.file_storage_migration_v2"

    public init(maxEntries: Int = 200, persistence: HistoryPersistence = UserDefaultsHistoryPersistence()) {
        self.maxEntries = max(1, maxEntries)
        self.persistence = persistence
        // Load persisted entries on init (nonisolated context, so we do it synchronously)
        if let data = try? persistence.data(forKey: Self.entriesKey),
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
        if !persistence.bool(forKey: Self.fileStorageMigrationKey) {
            logger.warning("⚠️ [HistoryStore] Upgrading to file-based storage. Clearing old history.")
            #if canImport(os)
            let logger = HypoLogger(category: "history")
            logger.info("🧹 Clearing old history for file storage migration")
            #endif
            self.entries.removeAll()
            // Clear persisted history
            try? persistence.removeValue(forKey: Self.entriesKey)
            // Initialize storage manager (clears files too if needed, though usually empty on first run)
            Task { @MainActor in
                StorageManager.shared.clearAll()
            }

            persistence.setBool(true, forKey: Self.fileStorageMigrationKey)
        }
    }

    /// Compatibility initializer: existing callers that construct a HistoryStore
    /// with a UserDefaults suite (e.g. for test isolation) need no changes.
    public init(maxEntries: Int = 200, defaults: UserDefaults) {
        self.init(maxEntries: maxEntries, persistence: UserDefaultsHistoryPersistence(defaults: defaults))
    }

    private func persistEntries() {
        let encoder = JSONEncoder()
        // Critical: Skip large data blobs when saving to UserDefaults
        encoder.userInfo[.skipLargeData] = true

        if let encoded = try? encoder.encode(self.entries) {
            try? persistence.setData(encoded, forKey: Self.entriesKey)
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
