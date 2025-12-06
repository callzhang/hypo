import Foundation
import CryptoKit

public enum TransportOrigin: String, Codable {
    case lan
    case cloud
}

public struct ClipboardEntry: Identifiable, Equatable, Codable {
    public let id: UUID
    public var timestamp: Date
    public let deviceId: String  // UUID string (pure UUID, no prefix) - normalized to lowercase
    public let originPlatform: DevicePlatform?  // Platform: macOS, Android, etc.
    public let originDeviceName: String?
    public let content: ClipboardContent
    public var isPinned: Bool
    public let isEncrypted: Bool  // Whether the message was encrypted
    public let transportOrigin: TransportOrigin?  // LAN or cloud relay

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        deviceId: String,
        originPlatform: DevicePlatform? = nil,
        originDeviceName: String? = nil,
        content: ClipboardContent,
        isPinned: Bool = false,
        isEncrypted: Bool = false,
        transportOrigin: TransportOrigin? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        // Normalize device ID to lowercase for consistent matching
        self.deviceId = deviceId.lowercased()
        self.originPlatform = originPlatform
        self.originDeviceName = originDeviceName
        self.content = content
        self.isPinned = isPinned
        self.isEncrypted = isEncrypted
        self.transportOrigin = transportOrigin
    }

    public func matches(query: String) -> Bool {
        let lowered = query.lowercased()
        if deviceId.contains(lowered) {
            return true
        }
        switch content {
        case .text(let text):
            return text.lowercased().contains(lowered)
        case .link(let url):
            return url.absoluteString.lowercased().contains(lowered)
        case .image(let metadata):
            return metadata.altText?.lowercased().contains(lowered) == true
        case .file(let metadata):
            return metadata.fileName.lowercased().contains(lowered)
        }
    }
}

public enum ClipboardContent: Equatable, Codable {
    case text(String)
    case link(URL)
    case image(ImageMetadata)
    case file(FileMetadata)

    public var title: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        }
    }

    public var iconName: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    public var previewDescription: String {
        switch self {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 100 ? "\(trimmed.prefix(100))…" : trimmed
        case .link(let url):
            let absolute = url.absoluteString
            return absolute.count > 100 ? "\(absolute.prefix(100))…" : absolute
        case .image(let metadata):
            if let fileName = metadata.altText, !fileName.isEmpty {
                return "\(fileName) · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
            }
            return "Image · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
        case .file(let metadata):
            return "\(metadata.fileName) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
        }
    }
    
    /// Returns true if this content type should show a preview button
    public var isPreviewable: Bool {
        switch self {
        case .text, .link:
            return false
        case .image, .file:
            return true
        }
    }
}

public struct ImageMetadata: Equatable, Codable {
    public let pixelSize: CGSizeValue
    public let byteSize: Int
    public let format: String
    public let altText: String?
    public let data: Data?
    public let thumbnail: Data?

    public init(pixelSize: CGSizeValue, byteSize: Int, format: String, altText: String?, data: Data?, thumbnail: Data?) {
        self.pixelSize = pixelSize
        self.byteSize = byteSize
        self.format = format
        self.altText = altText
        self.data = data
        self.thumbnail = thumbnail
    }
}

public struct FileMetadata: Equatable, Codable {
    public let fileName: String
    public let byteSize: Int
    public let uti: String
    public let url: URL?
    public let base64: String?

    public init(fileName: String, byteSize: Int, uti: String, url: URL?, base64: String?) {
        self.fileName = fileName
        self.byteSize = byteSize
        self.uti = uti
        self.url = url
        self.base64 = base64
    }
}

public struct CGSizeValue: Equatable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public extension ClipboardEntry {
    var previewText: String {
        content.previewDescription
    }
    
    /// Returns the display name for the origin device
    /// - Parameter localDeviceId: The current device's ID to compare against (will be normalized to lowercase)
    /// - Returns: "Local" if from this device, otherwise the device name or a fallback
    func originDisplayName(localDeviceId: String) -> String {
        if deviceId == localDeviceId.lowercased() {
            return "Local"
        }
        return originDeviceName ?? "Unknown Device"
    }
    
    /// Returns true if this entry is from the local device
    /// - Parameter localDeviceId: The current device's ID to compare against (will be normalized to lowercase)
    func isLocal(localDeviceId: String) -> Bool {
        deviceId == localDeviceId.lowercased()
    }

    func accessibilityDescription() -> String {
        switch content {
        case .text(let text):
            return "Text from \(deviceId): \(text)"
        case .link(let url):
            return "Link from \(deviceId): \(url.absoluteString)"
        case .image(let metadata):
            return "Image from \(deviceId), format \(metadata.format), size \(metadata.pixelSize.width) by \(metadata.pixelSize.height)"
        case .file(let metadata):
            return "File from \(deviceId): \(metadata.fileName)"
        }
    }

    func previewData() -> Data? {
        switch content {
        case .text(let text):
            return text.data(using: .utf8)
        case .link(let url):
            return url.absoluteString.data(using: .utf8)
        case .image(let metadata):
            // Return data if available (from pasteboard), otherwise nil (will be loaded async in preview)
            return metadata.data
        case .file(let metadata):
            // Only return base64 data if available (from remote origin)
            // Don't read from URL synchronously - let preview view handle async loading
            if let base64 = metadata.base64,
               let data = Data(base64Encoded: base64) {
                return data
            }
            // Return nil for local files - preview will load async
            return nil
        }
    }
    
    /// Unified content matching function: content length, then SHA-256 hash of full content
    /// Returns true if entries match based on the unified matching criteria
    /// Note: Metadata (device UUID, timestamp) is not used for matching - we match by content only
    func matchesContent(_ other: ClipboardEntry) -> Bool {
        // 1. Check content type
        switch (content, other.content) {
        case (.text(let text1), .text(let text2)):
            // For text: compare length first, then full-content SHA-256
            if text1.count != text2.count {
                return false
            }
            let data1 = Data(text1.utf8)
            let data2 = Data(text2.utf8)
            let hash1 = sha256(data1)
            let hash2 = sha256(data2)
            return hash1 == hash2
            
        case (.link(let url1), .link(let url2)):
            // For links: compare length first, then full-content SHA-256
            let str1 = url1.absoluteString
            let str2 = url2.absoluteString
            if str1.count != str2.count {
                return false
            }
            let data1 = Data(str1.utf8)
            let data2 = Data(str2.utf8)
            let hash1 = sha256(data1)
            let hash2 = sha256(data2)
            return hash1 == hash2
            
        case (.image(let meta1), .image(let meta2)):
            // For images: compare length (byteSize) first, then full-content SHA-256
            if meta1.byteSize != meta2.byteSize {
                return false
            }
            let data1 = meta1.data ?? Data()
            let data2 = meta2.data ?? Data()
            let hash1 = sha256(data1)
            let hash2 = sha256(data2)
            return hash1 == hash2
            
        case (.file(let meta1), .file(let meta2)):
            // For files: compare length (byteSize) first, then full-content SHA-256
            if meta1.byteSize != meta2.byteSize {
                return false
            }
            let data1: Data
            if let base64 = meta1.base64,
               let decoded = Data(base64Encoded: base64) {
                data1 = decoded
            } else if let url = meta1.url,
                      let loaded = try? Data(contentsOf: url) {
                data1 = loaded
            } else {
                return false
            }
            
            let data2: Data
            if let base64 = meta2.base64,
               let decoded = Data(base64Encoded: base64) {
                data2 = decoded
            } else if let url = meta2.url,
                      let loaded = try? Data(contentsOf: url) {
                data2 = loaded
            } else {
                return false
            }
            let hash1 = sha256(data1)
            let hash2 = sha256(data2)
            return hash1 == hash2
            
        default:
            return false
        }
    }
    
    /// Cryptographic hash (SHA-256) of the full content for content matching
    private func sha256(_ data: Data) -> Data {
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }
}
