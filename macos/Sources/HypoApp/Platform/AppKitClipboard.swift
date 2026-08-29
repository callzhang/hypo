import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// macOS implementation of SystemClipboard, backed by NSPasteboard.
#if canImport(AppKit)
public final class AppKitClipboard: SystemClipboard {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int {
        pasteboard.changeCount
    }

    public func clear() {
        pasteboard.clearContents()
    }

    public func writeText(_ text: String) {
        pasteboard.setString(text, forType: .string)
    }

    public func writeImageData(_ data: Data) -> Bool {
        guard let image = NSImage(data: data) else {
            return false
        }
        pasteboard.writeObjects([image])
        return true
    }

    public func writeFileURL(_ url: URL) {
        pasteboard.writeObjects([url as NSURL])
    }

    public func currentText() -> String? {
        guard let types = pasteboard.types, types.contains(.string) else {
            return nil
        }
        return pasteboard.string(forType: .string)
    }

    public func containsImage() -> Bool {
        let imageObjects = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.compactMap { $0 as? NSImage } ?? []
        return !imageObjects.isEmpty
    }

    public func imagePixelSize(from data: Data) -> (width: Int, height: Int)? {
        guard let image = NSImage(data: data) else {
            return nil
        }
        let size = image.size
        return (width: Int(size.width), height: Int(size.height))
    }
}
#endif
