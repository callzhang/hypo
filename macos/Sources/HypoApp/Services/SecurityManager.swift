import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Combine)
import Combine
#endif

/// Manages encryption keys and security-related operations.
@MainActor
public final class SecurityManager: ObservableObject {
    private let logger = HypoLogger(category: "Security")
    private let defaults: UserDefaults
    
    #if canImport(Combine)
    @Published public private(set) var encryptionKeySummary: String = ""
    #else
    public private(set) var encryptionKeySummary: String = ""
    #endif
    
    private enum DefaultsKey {
        static let encryptionKey = "encryption_key_summary"
    }
    
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.loadOrGenerateKey()
    }
    
    private func loadOrGenerateKey() {
        if let storedKey = defaults.string(forKey: DefaultsKey.encryptionKey) {
            self.encryptionKeySummary = storedKey
        } else {
            regenerateEncryptionKey()
        }
    }
    
    public func regenerateEncryptionKey() {
        let newKey = Self.generateEncryptionKey()
        encryptionKeySummary = newKey
        defaults.set(newKey, forKey: DefaultsKey.encryptionKey)
        logger.info("🔐 SecurityManager: Encryption key regenerated")
    }
    
    #if canImport(AppKit)
    public func copyEncryptionKeyToPasteboard() {
        guard !encryptionKeySummary.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(encryptionKeySummary, forType: .string)
        logger.info("📋 SecurityManager: Encryption key copied to pasteboard")
    }
    #endif
    
    /// Generates a new encryption key in the required format:
    /// UUID string, lowercased, without hyphens.
    private static func generateEncryptionKey() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
