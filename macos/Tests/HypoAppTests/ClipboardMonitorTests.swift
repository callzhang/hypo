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

    var types: [NSPasteboard.PasteboardType]? {
        Array(storage.keys)
    }

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
    }

    func setFile(url: URL) {
        changeCount += 1
        storage[.fileURL] = url
    }
}
#endif
