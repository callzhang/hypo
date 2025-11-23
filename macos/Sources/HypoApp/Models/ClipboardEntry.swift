import Foundation

public enum TransportOrigin: String, Codable {
    case lan
    case cloud
}

public struct ClipboardEntry: Identifiable, Equatable, Codable {
    public let id: UUID
    public var timestamp: Date
    public let originDeviceId: String  // UUID string (pure UUID, no prefix)
    public let originPlatform: DevicePlatform?  // Platform: macOS, Android, etc.
    public let originDeviceName: String?
    public let content: ClipboardContent
    public var isPinned: Bool
    public let isEncrypted: Bool  // Whether the message was encrypted
    public let transportOrigin: TransportOrigin?  // LAN or cloud relay

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        originDeviceId: String,
        originPlatform: DevicePlatform? = nil,
        originDeviceName: String? = nil,
        content: ClipboardContent,
        isPinned: Bool = false,
        isEncrypted: Bool = false,
        transportOrigin: TransportOrigin? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originDeviceId = originDeviceId
        self.originPlatform = originPlatform
        self.originDeviceName = originDeviceName
        self.content = content
        self.isPinned = isPinned
        self.isEncrypted = isEncrypted
        self.transportOrigin = transportOrigin
    }

    public func matches(query: String) -> Bool {
        let lowered = query.lowercased()
        if originDeviceId.lowercased().contains(lowered) {
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
    /// - Parameter localDeviceId: The current device's ID to compare against
    /// - Returns: "Local" if from this device, otherwise the device name or a fallback
    func originDisplayName(localDeviceId: String) -> String {
        if originDeviceId == localDeviceId {
            return "Local"
        }
        return originDeviceName ?? "Unknown Device"
    }
    
    /// Returns true if this entry is from the local device
    /// - Parameter localDeviceId: The current device's ID to compare against
    func isLocal(localDeviceId: String) -> Bool {
        originDeviceId == localDeviceId
    }

    func accessibilityDescription() -> String {
        switch content {
        case .text(let text):
            return "Text from \(originDeviceId): \(text)"
        case .link(let url):
            return "Link from \(originDeviceId): \(url.absoluteString)"
        case .image(let metadata):
            return "Image from \(originDeviceId), format \(metadata.format), size \(metadata.pixelSize.width) by \(metadata.pixelSize.height)"
        case .file(let metadata):
            return "File from \(originDeviceId): \(metadata.fileName)"
        }
    }

    func previewData() -> Data? {
        switch content {
        case .text(let text):
            return text.data(using: .utf8)
        case .link(let url):
            return url.absoluteString.data(using: .utf8)
        case .image(let metadata):
            return metadata.data
        case .file(let metadata):
            if let base64 = metadata.base64 {
                return Data(base64Encoded: base64)
            }
            return nil
        }
    }
    
    /// Generate a content signature for duplicate detection (matches Android's signature logic)
    /// This signature is used to detect duplicates from dual-send (LAN + cloud)
    func contentSignature() -> String {
        let contentType: String
        let contentString: String
        
        switch content {
        case .text(let text):
            contentType = "text"
            contentString = text
        case .link(let url):
            contentType = "link"
            contentString = url.absoluteString
        case .image(let metadata):
            contentType = "image"
            // Use actual image data hash for accurate duplicate detection
            // This prevents different images with same size from being treated as duplicates
            if let imageData = metadata.data {
                // Use a more robust hash: sample multiple points throughout the image
                // This reduces collisions while still being fast
                let sampleCount = min(16, max(4, imageData.count / 1000)) // Sample 4-16 points
                let step = max(1, imageData.count / sampleCount)
                var hash = 0
                
                // Hash first 2KB
                let startSize = min(2048, imageData.count)
                for byte in imageData.prefix(startSize) {
                    hash = hash &* 31 &+ Int(byte)
                }
                
                // Hash last 2KB
                let endSize = min(2048, imageData.count)
                for byte in imageData.suffix(endSize) {
                    hash = hash &* 31 &+ Int(byte)
                }
                
                // Hash evenly distributed samples throughout the image
                for i in 0..<sampleCount {
                    let offset = i * step
                    if offset < imageData.count {
                        hash = hash &* 31 &+ Int(imageData[offset])
                    }
                }
                
                // Include filename in signature if available (for file-based images)
                let fileNamePart = metadata.altText ?? ""
                contentString = "\(hash)|\(metadata.byteSize)|\(metadata.format)|\(fileNamePart)"
            } else {
                // Fallback to size+format if data is not available
                let fileNamePart = metadata.altText ?? ""
                contentString = "\(metadata.byteSize)|\(metadata.format)|\(fileNamePart)"
            }
        case .file(let metadata):
            contentType = "file"
            // Use fileName and byteSize as signature for files
            contentString = "\(metadata.fileName)|\(metadata.byteSize)"
        }
        
        // Match Android's signature format: type||content||metadata
        // For simplicity, we use originDeviceId as part of the signature to match Android's deviceId check
        return "\(contentType)||\(contentString)||\(originDeviceId)"
    }
}
