import Foundation

#if canImport(AppKit)
import AppKit

public protocol ClipboardMonitorDelegate: AnyObject {
    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry)
}

public final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private var changeCount: Int
    private var timer: Timer?
    private let history: HistoryStore
    public weak var delegate: ClipboardMonitorDelegate?

    public init(pasteboard: NSPasteboard = .general, history: HistoryStore = HistoryStore()) {
        self.pasteboard = pasteboard
        self.changeCount = pasteboard.changeCount
        self.history = history
    }

    deinit {
        stop()
    }

    public func start(interval: TimeInterval = 0.5) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard let types = pasteboard.types else { return }

        if types.contains(.string), let string = pasteboard.string(forType: .string) {
            let entry = ClipboardEntry(originDeviceId: "macos", content: .text(string))
            Task { await history.insert(entry) }
            delegate?.clipboardMonitor(self, didCapture: entry)
            return
        }

        if types.contains(.URL), let url = pasteboard.string(forType: .URL), let parsed = URL(string: url) {
            let entry = ClipboardEntry(originDeviceId: "macos", content: .link(parsed))
            Task { await history.insert(entry) }
            delegate?.clipboardMonitor(self, didCapture: entry)
            return
        }

        if types.contains(.png), let data = pasteboard.data(forType: .png) {
            let entry = ClipboardEntry(
                originDeviceId: "macos",
                content: .image(.init(
                    pixelSize: CGSizeValue(width: 0, height: 0),
                    byteSize: data.count,
                    format: "png",
                    altText: nil
                ))
            )
            Task { await history.insert(entry) }
            delegate?.clipboardMonitor(self, didCapture: entry)
            return
        }
    }
}
#endif
