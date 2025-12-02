import Foundation

public struct ClipboardEntry: Identifiable, Equatable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let originDeviceId: String
    public let originDeviceName: String?
    public let content: ClipboardContent
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        originDeviceId: String,
        originDeviceName: String? = nil,
        content: ClipboardContent,
        isPinned: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originDeviceId = originDeviceId
        self.originDeviceName = originDeviceName
        self.content = content
        self.isPinned = isPinned
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
            return "Image · \(metadata.format.uppercased()) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
        case .file(let metadata):
            return "\(metadata.fileName) · \(metadata.byteSize.formatted(.byteCount(style: .binary)))"
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
}
