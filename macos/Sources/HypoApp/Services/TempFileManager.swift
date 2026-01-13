import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os
#endif

/// Manages temporary files created for clipboard operations.
///
/// Features:
/// - Automatic cleanup after a delay (30 seconds)
/// - Cleanup when clipboard changes
/// - Periodic cleanup of old temp files
/// - Prevents disk space accumulation
@MainActor
public final class TempFileManager {
    private var tempFiles: Set<URL> = []
    private var cleanupTasks: [URL: Task<Void, Never>] = [:]
    private var periodicCleanupTask: Task<Void, Never>?
    #if canImport(AppKit)
    private let pasteboard: NSPasteboard
    #endif
    private var dispatcher: ClipboardEventDispatcher?
    
    #if canImport(os)
    private let logger = HypoLogger(category: "tempfiles")
    #endif
    
    public static let shared = TempFileManager()
    
    #if canImport(AppKit)
    private init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        startPeriodicCleanup()
        observeClipboardChanges()
    }
    #else
    private init() {
        startPeriodicCleanup()
    }
    #endif
    
    deinit {
        periodicCleanupTask?.cancel()
        // Can't call async cleanupAll() in deinit, so just cancel tasks
        for task in cleanupTasks.values {
            task.cancel()
        }
    }
    
    private static let cleanupDelay: TimeInterval = 30.0 // 30 seconds
    private static let periodicCleanupInterval: TimeInterval = 60.0 // 1 minute
    private static let maxTempFileAge: TimeInterval = 300.0 // 5 minutes
    
    /// Register a temporary file for automatic cleanup.
    /// The file will be deleted after CLEANUP_DELAY or when clipboard changes.
    public func registerTempFile(_ url: URL) {
        tempFiles.insert(url)
        #if canImport(os)
        logger.info("📁 Registered temp file: \(url.lastPathComponent) (\(tempFiles.count) total)")
        #endif
        
        // Cancel existing cleanup task for this file if any
        cleanupTasks[url]?.cancel()
        
        // Schedule cleanup after delay
        let task = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.cleanupDelay * 1_000_000_000))
            if !Task.isCancelled {
                await cleanupFile(url)
            }
        }
        cleanupTasks[url] = task
    }
    
    /// Immediately cleanup a specific file.
    public func cleanupFile(_ url: URL) async {
        guard tempFiles.contains(url) else { return }
        
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                tempFiles.remove(url)
                cleanupTasks.removeValue(forKey: url)?.cancel()
                #if canImport(os)
                logger.info("🗑️ Cleaned up temp file: \(url.lastPathComponent)")
                #endif
            }
        } catch {
            #if canImport(os)
            logger.warning("⚠️ Failed to cleanup temp file \(url.lastPathComponent): \(error.localizedDescription)")
            #endif
        }
    }
    
    /// Cleanup all registered temp files.
    public func cleanupAll() {
        let filesToCleanup = Array(tempFiles)

        for url in filesToCleanup {
            Task {
                await cleanupFile(url)
            }
        }
    }
    
    /// Start periodic cleanup of old temp files in temp directory.
    private func startPeriodicCleanup() {
        periodicCleanupTask?.cancel()
        periodicCleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.periodicCleanupInterval * 1_000_000_000))
                await cleanupOldTempFiles()
            }
        }
    }
    
    /// Cleanup old temp files in the temp directory that match our pattern.
    private func cleanupOldTempFiles() async {
        do {
            let tempDir = FileManager.default.temporaryDirectory
            let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.creationDateKey], options: [])
            let now = Date()
            var cleanedCount = 0
            
            for file in files {
                // Check if it's a temp file we might have created (starts with common prefixes)
                let fileName = file.lastPathComponent
                if fileName.hasPrefix("hypo_") || fileName.hasPrefix("clipboard-") {
                    if let attrs = try? file.resourceValues(forKeys: [.creationDateKey]),
                       let creationDate = attrs.creationDate {
                        let age = now.timeIntervalSince(creationDate)
                        if age > Self.maxTempFileAge {
                            do {
                                try FileManager.default.removeItem(at: file)
                                cleanedCount += 1
                                tempFiles.remove(file)
                                cleanupTasks.removeValue(forKey: file)?.cancel()
                            } catch {
                                #if canImport(os)
                                logger.warning("⚠️ Failed to delete old temp file \(fileName): \(error.localizedDescription)")
                                #endif
                            }
                        }
                    }
                }
            }
            
            if cleanedCount > 0 {
                #if canImport(os)
                logger.info("🧹 Periodic cleanup: removed \(cleanedCount) old temp files")
                #endif
            }
        } catch {
            #if canImport(os)
            logger.warning("⚠️ Error during periodic cleanup: \(error.localizedDescription)")
            #endif
        }
    }

    /// Configure the manager with a dispatcher for event-driven cleanup
    public func configure(dispatcher: ClipboardEventDispatcher) {
        self.dispatcher = dispatcher
        dispatcher.addClipboardAppliedHandler { [weak self] _ in
            self?.cleanupAll()
        }
    }
    
    /// Observe clipboard changes to cleanup temp files when clipboard changes.
    #if canImport(AppKit)
    private func observeClipboardChanges() {
        // Polling for clipboard changes
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            var lastChangeCount = self.pasteboard.changeCount
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Check every 2 seconds
                let currentChangeCount = self.pasteboard.changeCount
                if currentChangeCount != lastChangeCount {
                    lastChangeCount = currentChangeCount
                    self.cleanupAll()
                }
            }
        }
    }
    #endif
}

