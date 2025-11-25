import Foundation

#if canImport(AppKit)
import AppKit

public protocol ClipboardMonitorDelegate: AnyObject {
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry)
}

public protocol PasteboardProviding: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func readObjects(forClasses classes: [AnyClass], options: [NSPasteboard.ReadingOptionKey: Any]?) -> [Any]
}

extension NSPasteboard: PasteboardProviding {
    public func readObjects(forClasses classes: [AnyClass], options: [NSPasteboard.ReadingOptionKey: Any]?) -> [Any] {
        readObjects(forClasses: classes, options: options) ?? []
    }
}

public final class ClipboardMonitor {
    private let logger = HypoLogger(category: "ClipboardMonitor")
    private let pasteboard: PasteboardProviding
    private var changeCount: Int
    private var timer: Timer?
    private let throttle: TokenBucket
    private let maxAttachmentSize = 10 * 1024 * 1024 // 10MB (matches Android limit)
    private let deviceId: UUID
    private let platform: DevicePlatform
    private let deviceName: String
    public weak var delegate: ClipboardMonitorDelegate?
    
    public init(
        pasteboard: PasteboardProviding = NSPasteboard.general,
        throttle: TokenBucket = .clipboardThrottle(),
        deviceId: UUID,
        platform: DevicePlatform,
        deviceName: String
    ) {
        self.pasteboard = pasteboard
        self.changeCount = pasteboard.changeCount
        self.throttle = throttle
        self.deviceId = deviceId
        self.platform = platform
        self.deviceName = deviceName
        
        // Listen for notifications when remote clipboard is applied
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ClipboardAppliedFromRemote"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let changeCount = notification.userInfo?["changeCount"] as? Int {
                self?.changeCount = changeCount
            }
        }
    }

    deinit {
        stop()
    }

    public func start(interval: TimeInterval = 0.5) {
        stop()
        logger.info("🚀 [ClipboardMonitor] Starting clipboard monitoring (interval: \(interval)s)")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.evaluatePasteboard()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        logger.info("✅ [ClipboardMonitor] Timer started, delegate: \(delegate != nil ? "set" : "nil")")
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    func evaluatePasteboard() -> ClipboardEntry? {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != changeCount else { return nil }
        
        logger.debug("📋 [ClipboardMonitor] Clipboard changed: \(changeCount) -> \(currentChangeCount)")
        changeCount = currentChangeCount
        
        guard throttle.consume() else {
            logger.debug("⏭️ [ClipboardMonitor] Throttled, skipping")
            return nil
        }
        
        guard let types = pasteboard.types else {
            logger.debug("⏭️ [ClipboardMonitor] No pasteboard types")
            return nil
        }
        
        logger.debug("📋 [ClipboardMonitor] Processing clipboard types: \(types.map { $0.rawValue }.joined(separator: ", "))")

        // Check for images FIRST - images copied from files have both .tiff/.png AND .fileURL types,
        // so we need to prioritize image detection before file detection
        if let imageEntry = captureImage(types: types) {
            delegate?.clipboardMonitor(self, didCapture: imageEntry)
            return imageEntry
        }

        // Check for files - non-image files (files that aren't images)
        if let fileEntry = captureFile(types: types) {
            delegate?.clipboardMonitor(self, didCapture: fileEntry)
            return fileEntry
        }

        // Check for URLs (links)
        if types.contains(.URL), let urlString = pasteboard.string(forType: .URL), let url = URL(string: urlString) {
            let entry = ClipboardEntry(
                originDeviceId: deviceId.uuidString,
                originPlatform: platform,
                originDeviceName: deviceName,
                content: .link(url),
                isEncrypted: false,
                transportOrigin: nil  // Explicitly nil for local copies
            )
            logger.info("📋 [ClipboardMonitor] Captured local link: \(url.absoluteString.prefix(50))")
            delegate?.clipboardMonitor(self, didCapture: entry)
            return entry
        }

        // Check for plain text LAST - this catches text that isn't a file path or URL
        if types.contains(.string), let string = pasteboard.string(forType: .string), !string.isEmpty {
            let entry = ClipboardEntry(
                originDeviceId: deviceId.uuidString,
                originPlatform: platform,
                originDeviceName: deviceName,
                content: .text(string),
                isEncrypted: false,
                transportOrigin: nil  // Explicitly nil for local copies
            )
            logger.info("📋 [ClipboardMonitor] Captured local text: \(string.prefix(50))")
            delegate?.clipboardMonitor(self, didCapture: entry)
            return entry
        }
        
        return nil
    }
    
    /// Update the change count to prevent detecting a change that was just applied
    /// This is called after IncomingClipboardHandler applies a received clipboard
    public func updateChangeCount() {
        changeCount = pasteboard.changeCount
    }

    private func captureImage(types: [NSPasteboard.PasteboardType]) -> ClipboardEntry? {
        
        // Priority order for image types (most specific first)
        // Read raw data directly from pasteboard to preserve original format
        // NOTE: TIFF is intentionally excluded - macOS pasteboard often includes TIFF as a fallback
        // even when the original image is PNG/JPEG, which causes incorrect format detection
        let imageTypePriority: [(NSPasteboard.PasteboardType, String)] = [
            (NSPasteboard.PasteboardType("public.png"), "png"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpeg"),
            (NSPasteboard.PasteboardType("public.heic"), "heic"),
            (NSPasteboard.PasteboardType("public.heif"), "heif"),
            (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
            (NSPasteboard.PasteboardType("public.gif"), "gif"),
            (NSPasteboard.PasteboardType("public.webp"), "webp"),
            (NSPasteboard.PasteboardType("public.bmp"), "bmp"),
            (.png, "png")
        ]
        
        // Try each image type in priority order
        for (imageType, format) in imageTypePriority {
            if types.contains(imageType) {
                guard let rawData = pasteboard.data(forType: imageType) else {
                    continue
                }
                
                // Verify it's actually image data by trying to create NSImage
                guard let image = NSImage(data: rawData) else {
                    continue
                }
                
                let size = image.size
                let pixels = CGSizeValue(width: Int(size.width), height: Int(size.height))
                
                // Generate thumbnail for display
                let thumbnail = image.thumbnail(maxPixelSize: 128)
                
                // Check size limit on original data
                if rawData.count > maxAttachmentSize {
                    logger.warning("⚠️", "Image too large: \(rawData.count) bytes (limit: \(maxAttachmentSize))")
                    return nil
                }
                
                // Store original format as-is
                // Note: altText is nil for clipboard images (no filename available)
                let metadata = ImageMetadata(
                    pixelSize: pixels,
                    byteSize: rawData.count,
                    format: format,
                    altText: nil,
                    data: rawData,
                    thumbnail: thumbnail
                )
                
                
                return ClipboardEntry(originDeviceId: deviceId.uuidString, originPlatform: platform, originDeviceName: deviceName, content: .image(metadata), isEncrypted: false, transportOrigin: nil)
            }
        }
        
        // No fallback - if we can't get original format from pasteboard types, fail
        // This surfaces issues instead of silently converting to TIFF
        logger.error("❌ [ClipboardMonitor] No supported image format found in pasteboard types: \(types.map { $0.rawValue }.joined(separator: ", "))")
        return nil
    }

    private func captureFile(types: [NSPasteboard.PasteboardType]) -> ClipboardEntry? {
        guard types.contains(.fileURL) else {
            return nil
        }
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: nil).compactMap { $0 as? URL }
        guard let fileURL = objects.first else {
            return nil
        }
        
        // Check if this is an image file - if so, try to capture it as an image instead
        let uti = fileURL.typeIdentifier ?? "public.data"
        let imageUTIs: Set<String> = [
            "public.png", "public.jpeg", "public.tiff", "public.heic", "public.heif",
            "com.compuserve.gif", "public.gif", "public.webp", "public.bmp",
            "com.adobe.photoshop-image", "com.adobe.illustrator.ai-image"
        ]
        
        if imageUTIs.contains(uti) || uti.hasPrefix("public.image") {
            // This is an image file - try to read it as an image
            
            // Try to read as image
            if let imageData = try? Data(contentsOf: fileURL),
               let image = NSImage(data: imageData) {
                let size = image.size
                let pixels = CGSizeValue(width: Int(size.width), height: Int(size.height))
                let thumbnail = image.thumbnail(maxPixelSize: 128)
                
                // Determine format from UTI or file extension
                let format: String = {
                    if uti.contains("png") || fileURL.pathExtension.lowercased() == "png" {
                        return "png"
                    } else if uti.contains("jpeg") || uti.contains("jpg") || fileURL.pathExtension.lowercased() == "jpg" || fileURL.pathExtension.lowercased() == "jpeg" {
                        return "jpeg"
                    } else if uti.contains("heic") || uti.contains("heif") || fileURL.pathExtension.lowercased() == "heic" {
                        return "heic"
                    } else if uti.contains("gif") || fileURL.pathExtension.lowercased() == "gif" {
                        return "gif"
                    } else if uti.contains("webp") || fileURL.pathExtension.lowercased() == "webp" {
                        return "webp"
                    } else if uti.contains("bmp") || fileURL.pathExtension.lowercased() == "bmp" {
                        return "bmp"
                    } else if uti.contains("tiff") || fileURL.pathExtension.lowercased() == "tiff" || fileURL.pathExtension.lowercased() == "tif" {
                        return "tiff"
                    } else {
                        return "unknown"
                    }
                }()
                
                // Check size limit
                if imageData.count > maxAttachmentSize {
                    logger.warning("⚠️ [ClipboardMonitor] Image file too large: \(imageData.count) bytes (limit: \(maxAttachmentSize))")
                    return nil
                }
                
                // Store filename in altText for image files
                let fileName = fileURL.lastPathComponent
                let metadata = ImageMetadata(
                    pixelSize: pixels,
                    byteSize: imageData.count,
                    format: format,
                    altText: fileName,
                    data: imageData,
                    thumbnail: thumbnail
                )
                
                
                return ClipboardEntry(originDeviceId: deviceId.uuidString, originPlatform: platform, originDeviceName: deviceName, content: .image(metadata), isEncrypted: false, transportOrigin: nil)
            }
        }
        
        // Not an image file, or failed to read as image - treat as regular file
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxAttachmentSize else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let metadata = FileMetadata(
            fileName: fileURL.lastPathComponent,
            byteSize: size,
            uti: uti,
            url: fileURL,
            base64: data.base64EncodedString()
        )
        return ClipboardEntry(originDeviceId: deviceId.uuidString, originPlatform: platform, originDeviceName: deviceName, content: .file(metadata), isEncrypted: false, transportOrigin: nil)
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
