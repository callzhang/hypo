import Foundation
#if canImport(os)
import os.log
#endif

/// Centralized logging utility with custom formatting
/// Uses os.Logger for system integration but formats messages cleanly
public struct HypoLogger {
    #if canImport(os)
    private let logger: os.Logger
    #endif
    private let subsystem: String
    private let category: String
    
    public init(subsystem: String = "com.hypo.clipboard", category: String) {
        self.subsystem = subsystem
        self.category = category
        #if canImport(os)
        self.logger = os.Logger(subsystem: subsystem, category: category)
        #endif
    }
    
    // MARK: - Logging Methods
    
    /// Debug level logging - detailed information for debugging
    public func debug(_ message: String) {
        log(message, level: "Debug")
    }
    
    /// Info level logging - general informational messages
    public func info(_ message: String) {
        log(message, level: "Info")
    }
    
    /// Notice level logging - important but not error conditions
    public func notice(_ message: String) {
        log(message, level: "Notice")
    }
    
    /// Warning level logging - warning conditions
    public func warning(_ message: String) {
        log(message, level: "Warning")
    }
    
    /// Error level logging - error conditions
    public func error(_ message: String) {
        log(message, level: "Error")
    }
    
    /// Fault level logging - critical errors
    public func fault(_ message: String) {
        log(message, level: "Fault")
    }
    
    private func log(_ message: String, level: String) {
        // For os.Logger: just use the message as-is (system adds timestamp, level, process, subsystem:category)
        // For print(): format with timestamp and category for terminal viewing
        let timestamp = formatTimestamp()
        let printFormatted = "[\(timestamp)] \(level) \(ProcessInfo.processInfo.processName): [\(subsystem):\(category)] \(message)"
        
        #if canImport(os)
        // Use os.Logger so logs appear in log stream - system will add metadata
        switch level {
        case "Debug":
            logger.debug("\(message, privacy: .public)")
        case "Info":
            logger.info("\(message, privacy: .public)")
        case "Notice":
            logger.notice("\(message, privacy: .public)")
        case "Warning":
            logger.warning("\(message, privacy: .public)")
        case "Error":
            logger.error("\(message, privacy: .public)")
        case "Fault":
            logger.fault("\(message, privacy: .public)")
        default:
            logger.info("\(message, privacy: .public)")
        }
        #endif
        
        // Also print to stdout for terminal viewing with full formatting
        print(printFormatted)
    }
    
    private func formatTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
    
    // MARK: - Convenience Methods with Emoji Support
    
    /// Debug with emoji prefix
    public func debug(_ emoji: String, _ message: String) {
        debug("\(emoji) \(message)")
    }
    
    /// Info with emoji prefix
    public func info(_ emoji: String, _ message: String) {
        info("\(emoji) \(message)")
    }
    
    /// Notice with emoji prefix
    public func notice(_ emoji: String, _ message: String) {
        notice("\(emoji) \(message)")
    }
    
    /// Warning with emoji prefix
    public func warning(_ emoji: String, _ message: String) {
        warning("\(emoji) \(message)")
    }
    
    /// Error with emoji prefix
    public func error(_ emoji: String, _ message: String) {
        error("\(emoji) \(message)")
    }
    
    /// Fault with emoji prefix
    public func fault(_ emoji: String, _ message: String) {
        fault("\(emoji) \(message)")
    }
}

// MARK: - Extension for String appendToFile (to be removed)
extension String {
    @discardableResult
    func appendToFile(path: String) -> Bool {
        // No-op - file logging removed in favor of os_log
        return true
    }
}

