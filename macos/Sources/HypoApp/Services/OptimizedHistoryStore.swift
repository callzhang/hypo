import Foundation
import os.log

/// Optimized memory management for clipboard history
public actor OptimizedHistoryStore {
    private var entries: [ClipboardEntry] = []
    private var indexedByContent: [String: Int] = [:]
    private var indexedByID: [UUID: Int] = [:]
    private var maxEntries: Int
    private var lastCleanup: Date = Date()
    private let cleanupInterval: TimeInterval = 300 // 5 minutes
    
    private let logger = HypoLogger(category: "history")
    
    public init(maxEntries: Int = 200) {
        self.maxEntries = max(1, maxEntries)
    }
    
    // MARK: - Optimized Insertion
    @discardableResult
    public func insert(_ entry: ClipboardEntry) -> [ClipboardEntry] {
        // Check for duplicates using indexed lookup (O(1) instead of O(n))
        let contentKey = entry.content.searchableText
        
        if let existingIndex = indexedByContent[contentKey] ?? indexedByID[entry.id] {
            // Remove existing entry
            let removedEntry = entries.remove(at: existingIndex)
            updateIndicesAfterRemoval(at: existingIndex)
            
            // Remove from indices
            indexedByContent.removeValue(forKey: removedEntry.content.searchableText)
            indexedByID.removeValue(forKey: removedEntry.id)
        }
        
        // Add new entry
        entries.append(entry)
        let newIndex = entries.count - 1
        indexedByContent[contentKey] = newIndex
        indexedByID[entry.id] = newIndex
        
        // Sort and trim
        sortEntriesOptimized()
        trimIfNeeded()
        
        // Periodic cleanup
        performPeriodicCleanup()
        
        return entries
    }
    
    // MARK: - Optimized Queries
    public func all() -> [ClipboardEntry] {
        performPeriodicCleanup()
        return entries
    }
    
    public func recent(_ count: Int) -> [ClipboardEntry] {
        let limitedCount = min(count, entries.count)
        return Array(entries.prefix(limitedCount))
    }
    
    public func entry(withID id: UUID) -> ClipboardEntry? {
        guard let index = indexedByID[id], index < entries.count else { return nil }
        return entries[index]
    }
    
    public func search(_ query: String) -> [ClipboardEntry] {
        guard !query.isEmpty else { return entries }
        
        let lowercaseQuery = query.lowercased()
        return entries.filter { entry in
            entry.content.searchableText.lowercased().contains(lowercaseQuery)
        }
    }
    
    // MARK: - Optimized Removal
    public func remove(id: UUID) {
        guard let index = indexedByID[id] else { return }
        let removedEntry = entries.remove(at: index)
        updateIndicesAfterRemoval(at: index)
        
        // Remove from indices
        indexedByContent.removeValue(forKey: removedEntry.content.searchableText)
        indexedByID.removeValue(forKey: removedEntry.id)
    }
    
    public func clear() {
        entries.removeAll()
        indexedByContent.removeAll()
        indexedByID.removeAll()
    }
    
    // MARK: - Memory Optimization
    @discardableResult
    public func updatePinState(id: UUID, isPinned: Bool) -> [ClipboardEntry] {
        guard let index = indexedByID[id] else { return entries }
        entries[index].isPinned = isPinned
        sortEntriesOptimized()
        return entries
    }
    
    @discardableResult
    public func updateLimit(_ newLimit: Int) -> [ClipboardEntry] {
        maxEntries = max(1, newLimit)
        trimIfNeeded()
        return entries
    }
    
    public func limit() -> Int { maxEntries }
    
    public func memoryUsage() -> (entryCount: Int, indexSize: Int, estimatedBytes: Int) {
        let indexSize = indexedByContent.count + indexedByID.count
        let estimatedBytes = entries.reduce(0) { total, entry in
            total + entry.estimatedMemoryFootprint
        }
        return (entryCount: entries.count, indexSize: indexSize, estimatedBytes: estimatedBytes)
    }
    
    // MARK: - Private Optimizations
    private func sortEntriesOptimized() {
        // Use stable sort for better performance on partially sorted data
        entries.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.timestamp > rhs.timestamp
        }
        rebuildIndices()
    }
    
    private func trimIfNeeded() {
        guard entries.count > maxEntries else { return }
        
        // Keep pinned items even if exceeding limit
        let pinnedCount = entries.prefix(maxEntries).filter(\.isPinned).count
        let unpinnedToKeep = maxEntries - pinnedCount
        
        var keptEntries: [ClipboardEntry] = []
        var pinnedKept = 0
        var unpinnedKept = 0
        
        for entry in entries {
            if entry.isPinned {
                keptEntries.append(entry)
                pinnedKept += 1
            } else if unpinnedKept < unpinnedToKeep {
                keptEntries.append(entry)
                unpinnedKept += 1
            }
        }
        
        entries = keptEntries
        rebuildIndices()
        
        logger.debug("Trimmed history: kept \(pinnedKept) pinned, \(unpinnedKept) unpinned entries")
    }
    
    private func updateIndicesAfterRemoval(at removedIndex: Int) {
        // Update indices for entries that were shifted
        for (key, index) in indexedByContent {
            if index > removedIndex {
                indexedByContent[key] = index - 1
            }
        }
        
        for (key, index) in indexedByID {
            if index > removedIndex {
                indexedByID[key] = index - 1
            }
        }
    }
    
    private func rebuildIndices() {
        indexedByContent.removeAll(keepingCapacity: true)
        indexedByID.removeAll(keepingCapacity: true)
        
        for (index, entry) in entries.enumerated() {
            indexedByContent[entry.content.searchableText] = index
            indexedByID[entry.id] = index
        }
    }
    
    private func performPeriodicCleanup() {
        let now = Date()
        guard now.timeIntervalSince(lastCleanup) > cleanupInterval else { return }
        
        lastCleanup = now
        
        // Remove any corrupted indices
        let validIDs = Set(entries.map(\.id))
        let validContent = Set(entries.map { $0.content.searchableText })
        
        indexedByID = indexedByID.filter { validIDs.contains($0.key) }
        indexedByContent = indexedByContent.filter { validContent.contains($0.key) }
        
        let usage = memoryUsage()
        logger.debug("Memory usage: \(usage.entryCount) entries, \(usage.indexSize) indices, ~\(usage.estimatedBytes) bytes")
    }
}

// MARK: - Extensions for Memory Optimization
extension ClipboardEntry {
    var estimatedMemoryFootprint: Int {
        var size = 0
        
        // UUID (16 bytes) + Date (8 bytes) + Bool (1 byte) + String (originDeviceId)
        size += 25 + originDeviceId.utf8.count
        
        // Content estimation
        switch content {
        case .text(let text):
            size += text.utf8.count
        case .link(let url):
            size += url.absoluteString.utf8.count
        case .image(let metadata):
            size += metadata.byteSize + (metadata.thumbnail?.count ?? 0)
        case .file(let metadata):
            size += metadata.fileName.utf8.count + metadata.byteSize
        }
        
        return size
    }
}

extension ClipboardContent {
    var searchableText: String {
        switch self {
        case .text(let text):
            return text
        case .link(let url):
            return url.absoluteString
        case .image:
            return "image"
        case .file(let metadata):
            return metadata.fileName
        }
    }
}