import Foundation

#if canImport(AppKit)
import AppKit

public protocol ClipboardMonitorDelegate: AnyObject {
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry)
}

protocol PasteboardProviding: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func readObjects(forClasses classes: [AnyClass], options: [NSPasteboard.ReadingOptionKey: Any]?) -> [Any]
}

extension NSPasteboard: PasteboardProviding {
    func readObjects(forClasses classes: [AnyClass], options: [NSPasteboard.ReadingOptionKey: Any]?) -> [Any] {
        readObjects(forClasses: classes, options: options) ?? []
    }
}

public final class ClipboardMonitor {
    private let pasteboard: PasteboardProviding
    private var changeCount: Int
    private var timer: Timer?
    private let throttle: TokenBucket
    private let maxAttachmentSize = 1_048_576
    public weak var delegate: ClipboardMonitorDelegate?

    public init(
        pasteboard: PasteboardProviding = NSPasteboard.general,
        throttle: TokenBucket = .clipboardThrottle()
    ) {
        self.pasteboard = pasteboard
        self.changeCount = pasteboard.changeCount
        self.throttle = throttle
    }

    deinit {
        stop()
    }

    public func start(interval: TimeInterval = 0.5) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.evaluatePasteboard()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    func evaluatePasteboard() -> ClipboardEntry? {
        guard pasteboard.changeCount != changeCount else { return nil }
        changeCount = pasteboard.changeCount
        guard throttle.consume() else { return nil }
        guard let types = pasteboard.types else { return nil }

        if types.contains(.string), let string = pasteboard.string(forType: .string), !string.isEmpty {
            let entry = ClipboardEntry(originDeviceId: "macos", content: .text(string))
            delegate?.clipboardMonitor(self, didCapture: entry)
            return entry
        }

        if types.contains(.URL), let urlString = pasteboard.string(forType: .URL), let url = URL(string: urlString) {
            let entry = ClipboardEntry(originDeviceId: "macos", content: .link(url))
            delegate?.clipboardMonitor(self, didCapture: entry)
            return entry
        }

        if let imageEntry = captureImage(types: types) {
            delegate?.clipboardMonitor(self, didCapture: imageEntry)
            return imageEntry
        }

        if let fileEntry = captureFile(types: types) {
            delegate?.clipboardMonitor(self, didCapture: fileEntry)
            return fileEntry
        }

        return nil
    }

    private func captureImage(types: [NSPasteboard.PasteboardType]) -> ClipboardEntry? {
        guard types.contains(.tiff) || types.contains(.png) else { return nil }
        let preferredType: NSPasteboard.PasteboardType = types.contains(.png) ? .png : .tiff
        guard let rawData = pasteboard.data(forType: preferredType) else { return nil }
        guard let image = NSImage(data: rawData) else { return nil }
        let size = image.size
        let pixels = CGSizeValue(width: Int(size.width), height: Int(size.height))
        let thumbnail = image.thumbnail(maxPixelSize: 128)
        let compressedData: Data
        let format: String
        if rawData.count > maxAttachmentSize || preferredType == .tiff {
            if let png = image.pngData(compressionQuality: 0.8) {
                compressedData = png
                format = "png"
            } else {
                compressedData = rawData
                format = preferredType == .png ? "png" : "tiff"
            }
        } else {
            compressedData = rawData
            format = preferredType == .png ? "png" : "tiff"
        }
        let metadata = ImageMetadata(
            pixelSize: pixels,
            byteSize: compressedData.count,
            format: format,
            altText: nil,
            data: compressedData,
            thumbnail: thumbnail
        )
        return ClipboardEntry(originDeviceId: "macos", content: .image(metadata))
    }

    private func captureFile(types: [NSPasteboard.PasteboardType]) -> ClipboardEntry? {
        guard types.contains(.fileURL) else { return nil }
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil).compactMap { $0 as? URL }
        guard let fileURL = objects.first else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxAttachmentSize else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let metadata = FileMetadata(
            fileName: fileURL.lastPathComponent,
            byteSize: size,
            uti: fileURL.typeIdentifier ?? "public.data",
            url: fileURL,
            base64: data.base64EncodedString()
        )
        return ClipboardEntry(originDeviceId: "macos", content: .file(metadata))
    }
}

private extension NSImage {
    func thumbnail(maxPixelSize: CGFloat) -> Data? {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxPixelSize else { return pngData(compressionQuality: 0.8) }
        let scale = maxPixelSize / longestSide
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let thumbnail = NSImage(size: newSize)
        thumbnail.lockFocus()
        defer { thumbnail.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: newSize))
        return thumbnail.pngData(compressionQuality: 0.8)
    }

    func pngData(compressionQuality: CGFloat) -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [.compressionFactor: compressionQuality])
    }
}

private extension URL {
    var typeIdentifier: String? {
        (try? resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier
    }
}
#endif
