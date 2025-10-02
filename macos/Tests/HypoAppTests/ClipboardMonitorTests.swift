#if canImport(AppKit)
import XCTest
import AppKit
@testable import HypoApp

final class ClipboardMonitorTests: XCTestCase {
    func testEvaluatePasteboardCapturesString() {
        let pasteboard = MockPasteboard()
        pasteboard.setString("Hello", for: .string)

        let monitor = ClipboardMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 10, refillInterval: 0.01))
        let delegate = CapturingDelegate()
        monitor.delegate = delegate

        let entry = monitor.evaluatePasteboard()

        XCTAssertEqual(delegate.entries.count, 1)
        XCTAssertEqual(entry?.content, ClipboardContent.text("Hello"))
    }

    func testRateLimiterPreventsRapidCaptures() {
        let pasteboard = MockPasteboard()
        pasteboard.setString("One", for: .string)
        let monitor = ClipboardMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 1, refillInterval: 5))
        monitor.evaluatePasteboard()

        pasteboard.setString("Two", for: .string)
        let secondEntry = monitor.evaluatePasteboard()

        XCTAssertNil(secondEntry)
    }

    func testCapturesFileMetadataWithinLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data(repeating: 0xA, count: 2048)
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = MockPasteboard()
        pasteboard.setFile(url: fileURL)
        let monitor = ClipboardMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 1, refillInterval: 0.01))

        let entry = monitor.evaluatePasteboard()

        guard case let .file(metadata)? = entry?.content else {
            return XCTFail("Expected file metadata")
        }
        XCTAssertEqual(metadata.byteSize, data.count)
        XCTAssertNotNil(metadata.base64)
    }

    func testSkipsFilesOverSizeLimit() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let largeData = Data(repeating: 0xB, count: 1_200_000)
        try largeData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = MockPasteboard()
        pasteboard.setFile(url: fileURL)
        let monitor = ClipboardMonitor(pasteboard: pasteboard, throttle: TokenBucket(capacity: 1, refillInterval: 0.01))

        XCTAssertNil(monitor.evaluatePasteboard())
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
