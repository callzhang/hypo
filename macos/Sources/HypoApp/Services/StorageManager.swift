import Foundation
#if canImport(os)
import os.log
#endif

/// Manages file-based storage for large clipboard items (images, files)
/// Stores data in ~/Library/Caches/com.hypo.clipboard/images/ to avoid bloating UserDefaults
public final class StorageManager {
    public static let shared = StorageManager()
    
    // Use Caches directory so the OS can clean it up if needed, but it persists across reboots
    private let baseDirectory: URL
    private let imagesDirectory: URL
    
    #if canImport(os)
    private let logger = HypoLogger(category: "StorageManager")
    #endif
    
    private init() {
        // Base: ~/Library/Caches/com.hypo.clipboard/
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hypo.clipboard"
        baseDirectory = caches.appendingPathComponent(bundleID)
        imagesDirectory = baseDirectory.appendingPathComponent("images")
        
        createDirectoriesIfNeeded()
    }
    
    private func createDirectoriesIfNeeded() {
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
    /// - Returns: The relative path (filename) of the saved file
    public func save(_ data: Data, id: UUID = UUID(), `extension`: String = "data") throws -> String {
        let fileName = "\(id.uuidString).\(`extension`)"
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        
        try data.write(to: fileURL)
        #if canImport(os)
        logger.debug("💾 [StorageManager] Saved \(data.count) bytes to \(fileName)")
        #endif
        
        return fileName
    }
    
    /// Read data from a relative path (filename)
    /// - Parameter relativePath: The filename returned by save()
    /// - Returns: The data, or nil if not found
    public func load(relativePath: String) -> Data? {
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
