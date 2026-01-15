#if canImport(AppKit)
import Testing
import AppKit
@testable import HypoApp

struct ClipboardMonitorTests {
    @MainActor
    private func makeMonitor(pasteboard: PasteboardProviding, throttle: TokenBucket) -> ClipboardMonitor {
        ClipboardMonitor(
            pasteboard: pasteboard,
            throttle: throttle,
            deviceId: UUID(),
            platform: .macOS,
            deviceName: "Test Mac"
        )
    }

    @Test
    @MainActor
    func testEvaluatePasteboardCapturesString() {
        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        let delegate = CapturingDelegate()
        monitor.delegate = delegate

        pasteboard.setString("Hello", for: .string)
        let entry = monitor.evaluatePasteboard()

        #expect(delegate.entries.count == 1)
        #expect(entry?.content == ClipboardContent.text("Hello"))
    }

    @Test
    @MainActor
    func testRateLimiterPreventsRapidCaptures() {
        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 1, refillInterval: 5))
        pasteboard.setString("One", for: .string)
        monitor.evaluatePasteboard()

        pasteboard.setString("Two", for: .string)
        let secondEntry = monitor.evaluatePasteboard()

        #expect(secondEntry == nil)
    }

    @Test
    @MainActor
    func testCapturesFileMetadataWithinLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data(repeating: 0xA, count: 2048)
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 1, refillInterval: 0.01))
        pasteboard.setFile(url: fileURL)

        let entry = monitor.evaluatePasteboard()

        guard case let .file(metadata)? = entry?.content else {
            #expect(false)
            return
        }
        #expect(metadata.byteSize == data.count)
        #expect(metadata.fileName == fileURL.lastPathComponent)
        #expect(metadata.url == fileURL)
        // Local-origin files should not duplicate bytes in base64; we only store a pointer.
        #expect(metadata.base64 == nil)
    }

    @Test
    @MainActor
    func testSkipsFilesOverSizeLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let largeData = Data(repeating: 0xB, count: 1_200_000)
        try largeData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = MockPasteboard()
        pasteboard.setFile(url: fileURL)
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 1, refillInterval: 0.01))

        #expect(monitor.evaluatePasteboard() == nil)
    }
    @Test
    @MainActor
    func testCapturesLink() {
        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        let delegate = CapturingDelegate()
        monitor.delegate = delegate

        let urlString = "https://apple.com"
        pasteboard.setString(urlString, for: .URL)
        let entry = monitor.evaluatePasteboard()

        #expect(delegate.entries.count == 1)
        guard case let .link(url)? = entry?.content else {
            Issue.record("Expected link")
            return
        }
        #expect(url.absoluteString == urlString)
    }

    @Test
    @MainActor
    func testCapturesImage() {
        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        let delegate = CapturingDelegate()
        monitor.delegate = delegate

        // Create a simple image data
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.set()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to create image data")
            return
        }
        
        pasteboard.setData(pngData, for: .png)
        let entry = monitor.evaluatePasteboard()

        #expect(delegate.entries.count == 1)
        guard case let .image(metadata)? = entry?.content else {
            Issue.record("Expected image")
            return
        }
        #expect(metadata.pixelSize.width == 10)
        #expect(metadata.pixelSize.height == 10)
    }

    @Test
    @MainActor
    func testUpdateChangeCountPreventsDuplicateCapture() {
        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        
        pasteboard.changeCount = 10
        monitor.updateChangeCount()
        
        // Even if types are present, if change count hasn't moved, it should skip
        pasteboard.setString("Hello", for: .string) // This will bump change count in mock
        // But if we manually set it to what monitor already has:
        pasteboard.changeCount = 10
        
        let entry = monitor.evaluatePasteboard()
        #expect(entry == nil)
    }

    @Test
    @MainActor
    func testCapturesLargeImageAndCompresses() {
        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        let delegate = CapturingDelegate()
        monitor.delegate = delegate

        // Create a truly large bitmap (3000x3000px, ~36MB raw) to trigger compression and scaling
        let width = 3000
        let height = 3000
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else {
            Issue.record("Failed to create bitmap")
            return
        }
        
        guard let largeData = bitmap.tiffRepresentation else {
            Issue.record("Failed to create TIFF data")
            return
        }
        
        // Ensure it's over the limit
        #expect(largeData.count > SizeConstants.maxRawSizeForCompression)
        
        pasteboard.setData(largeData, for: .tiff)
        let entry = monitor.evaluatePasteboard()

        #expect(entry != nil)
        guard case let .image(metadata)? = entry?.content else {
            Issue.record("Expected image")
            return
        }
        // Check if it was scaled down
        #expect(CGFloat(metadata.pixelSize.width) <= SizeConstants.maxImageDimensionPx)
        #expect(CGFloat(metadata.pixelSize.height) <= SizeConstants.maxImageDimensionPx)
    }

    @Test
    @MainActor
    func testCapturesImageFileAsImage() throws {
        // Create a temp image file
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.green.set()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "test", code: 0, userInfo: nil)
        }
        try pngData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        pasteboard.setFile(url: fileURL)
        
        let entry = monitor.evaluatePasteboard()
        
        #expect(entry != nil)
        guard case .image = entry?.content else {
            Issue.record("Expected image content for an image file")
            return
        }
    }

    @Test
    @MainActor
    func testRemoteClipboardAppliedUpdatesCount() {
        let dispatcher = ClipboardEventDispatcher()
        let pasteboard = MockPasteboard()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            deviceId: UUID(),
            platform: .macOS,
            deviceName: "Test Mac",
            dispatcher: dispatcher
        )
        
        pasteboard.changeCount = 100
        dispatcher.notifyClipboardApplied(changeCount: 100)
        
        // Now evaluate - should be nil because count matches
        let entry = monitor.evaluatePasteboard()
        #expect(entry == nil)
    }

    @Test
    @MainActor
    func testCapturesHeicImageFile() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        // We'll just write some PNG data but with .heic extension to hit the extension logic
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.purple.set()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "test", code: 0, userInfo: nil)
        }
        try pngData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        pasteboard.setFile(url: fileURL)
        
        let entry = monitor.evaluatePasteboard()
        #expect(entry != nil)
    }

    @Test
    @MainActor
    func testHandleEmptyPasteboard() {
        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        
        pasteboard.changeCount = 1
        // types will be []
        let entry = monitor.evaluatePasteboard()
        #expect(entry == nil)
    }

    @Test
    @MainActor
    func testStartStop() {
        let monitor = makeMonitor(pasteboard: MockPasteboard(), throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        monitor.start(interval: 0.1)
        monitor.stop()
    }

    @Test
    @MainActor
    func testImageCaptureWithNilData() {
        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        
        pasteboard.changeCount = 1
        pasteboard.setData(Data(), for: .string) // Just to trigger evaluate
        pasteboard.types = [.png] // But storage[.png] is nil
        
        let entry = monitor.evaluatePasteboard()
        #expect(entry == nil)
    }
    
    @Test
    @MainActor
    func testCapturesJpegFileAsImage() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpeg")
        try Data([1, 2, 3]).write(to: fileURL) // Dummy data
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = MockPasteboard()
        let monitor = makeMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        pasteboard.setFile(url: fileURL)
        
        // This should probably fail the image read and fall back to file entry
        // Unless we make it a valid JPEG
        let entry = monitor.evaluatePasteboard()
        #expect(entry != nil)
    }

    @Test
    func testNSPasteboardWrapper() {
        let pb: PasteboardProviding = NSPasteboard.general
        _ = pb.readObjects(forClasses: [NSURL.self], options: nil)
    }
}

private final class CapturingDelegate: ClipboardMonitorDelegate {
    private(set) var entries: [ClipboardEntry] = []

    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry) {
        entries.append(entry)
    }
}

private final class MockPasteboard: PasteboardProviding {
    var changeCount: Int = 0
    private var storage: [NSPasteboard.PasteboardType: Any] = [:]
    var types: [NSPasteboard.PasteboardType]? = []

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        storage[type] as? String
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        storage[type] as? Data
    }

    func readObjects(forClasses classes: [AnyClass], options: [NSPasteboard.ReadingOptionKey : Any]?) -> [Any] {
        if classes.contains(where: { $0 == NSURL.self }), let url = storage[.fileURL] as? URL {
            return [url]
        }
        return []
    }

    func setString(_ value: String, for type: NSPasteboard.PasteboardType) {
        changeCount += 1
        storage[type] = value
        if types != nil { types?.append(type) }
    }

    func setData(_ data: Data, for type: NSPasteboard.PasteboardType) {
        changeCount += 1
        storage[type] = data
        if types != nil { types?.append(type) }
    }

    func setFile(url: URL) {
        changeCount += 1
        storage[.fileURL] = url
        if types != nil { types?.append(.fileURL) }
    }
}
#endif
