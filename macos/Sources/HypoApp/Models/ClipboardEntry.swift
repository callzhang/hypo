import Foundation

public struct ClipboardEntry: Identifiable, Equatable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let originDeviceId: String
    public let content: ClipboardContent
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        originDeviceId: String,
        content: ClipboardContent,
        isPinned: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.originDeviceId = originDeviceId
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
}

public struct ImageMetadata: Equatable, Codable {
    public let pixelSize: CGSizeValue
    public let byteSize: Int
    public let format: String
    public let altText: String?

    public init(pixelSize: CGSizeValue, byteSize: Int, format: String, altText: String?) {
        self.pixelSize = pixelSize
        self.byteSize = byteSize
        self.format = format
        self.altText = altText
    }
}

public struct FileMetadata: Equatable, Codable {
    public let fileName: String
    public let byteSize: Int
    public let uti: String

    public init(fileName: String, byteSize: Int, uti: String) {
        self.fileName = fileName
        self.byteSize = byteSize
        self.uti = uti
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
