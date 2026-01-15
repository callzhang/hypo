import Foundation
#if canImport(os)
import os.log
#endif

/// Manages file-based storage for large clipboard items (images, files)
/// Stores data in ~/Library/Caches/com.hypo.clipboard/images/ to avoid bloating UserDefaults
@MainActor
public final class StorageManager {
    // Accessed from non-MainActor contexts (e.g., model helpers); file IO here is thread-safe.
    nonisolated public static let shared = StorageManager()
    
    // Use Caches directory so the OS can clean it up if needed, but it persists across reboots
    private let baseDirectory: URL
    private let imagesDirectory: URL
    
    #if canImport(os)
    private let logger = HypoLogger(category: "StorageManager")
    #endif
    
    nonisolated private init() {
        // Base: ~/Library/Caches/com.hypo.clipboard/
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hypo.clipboard"
        baseDirectory = caches.appendingPathComponent(bundleID)
        imagesDirectory = baseDirectory.appendingPathComponent("images")
        
        createDirectoriesIfNeeded()
    }
    
    nonisolated private func createDirectoriesIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        } catch {
            #if canImport(os)
            logger.error("❌ [StorageManager] Failed to create images directory: \(error.localizedDescription)")
            #endif
        }
    }
    
    /// Setup function to be called at app launch
    public func setup() {
        createDirectoriesIfNeeded()
        #if canImport(os)
        logger.info("📂 [StorageManager] Storage initialized at: \(imagesDirectory.path)")
        #endif
    }
    
    /// Write data to a new file in the storage directory
    /// - Parameters:
    ///   - data: The binary data to save
    ///   - fileName: Optional filename (UUID string usually)
    ///   - extension: File extension (e.g. png, jpg)
    /// - Returns: The relative path (filename)
    @discardableResult
    public nonisolated func save(_ data: Data, id: UUID = UUID(), `extension` ext: String = "data") -> String? {
        let fileName = "\(id.uuidString).\(ext)"
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        
        do {
            try data.write(to: fileURL)
            #if canImport(os)
            logger.debug("💾 [StorageManager] Saved \(data.count / 1024)KB to \(fileName)")
            #endif
            return fileName
        } catch {
            #if canImport(os)
            logger.error("❌ [StorageManager] Failed to save data: \(error.localizedDescription)")
            #endif
            return nil
        }
    }
    
    /// Read data from a relative path (filename)
    /// - Parameter relativePath: The filename returned by save()
    /// - Returns: The data, or nil if not found
    public nonisolated func load(relativePath: String) -> Data? {
        let fileURL = imagesDirectory.appendingPathComponent(relativePath)
        return try? Data(contentsOf: fileURL)
    }
    
    /// Get the full URL for a relative path (useful for NSImage/Preview)
    public func url(for relativePath: String) -> URL {
        return imagesDirectory.appendingPathComponent(relativePath)
    }
    
    /// Delete a file
    public func delete(relativePath: String) {
        let fileURL = imagesDirectory.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    /// Clear all stored files (useful for migration or user request)
    public func clearAll() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)
            for url in contents {
                try FileManager.default.removeItem(at: url)
            }
            #if canImport(os)
            logger.info("🧹 [StorageManager] Cleared all stored files")
            #endif
        } catch {
            #if canImport(os)
            logger.error("❌ [StorageManager] Failed to clear storage: \(error.localizedDescription)")
            #endif
        }
    }
}
