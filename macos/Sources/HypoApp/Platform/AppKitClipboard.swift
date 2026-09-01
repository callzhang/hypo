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
        // Put the received bytes on the pasteboard as they arrived.
        //
        // Writing an `NSImage` instead decodes and re-encodes, so the bytes that
        // come back out are never the bytes that went in -- which defeats every
        // check that asks "is this the item we just applied?" and turns a synced
        // image into one that bounces between devices, re-encoded each hop. It also
        // writes lazily, changing the pasteboard again after we have read its change
        // count to suppress exactly this.
        guard let type = Self.pasteboardType(for: data) else {
            // An encoding we cannot name: fall back rather than drop the image.
            guard let image = NSImage(data: data) else { return false }
            pasteboard.writeObjects([image])
            return true
        }
        pasteboard.setData(data, forType: type)
        return true
    }

    /// Identifies the encoding from its magic bytes, since the sender's declared
    /// format does not reach this far.
    static func pasteboardType(for data: Data) -> NSPasteboard.PasteboardType? {
        let prefix = [UInt8](data.prefix(8))
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return NSPasteboard.PasteboardType("public.jpeg") }
        if prefix.starts(with: [0x47, 0x49, 0x46]) { return NSPasteboard.PasteboardType("com.compuserve.gif") }
        if prefix.starts(with: [0x49, 0x49, 0x2A]) || prefix.starts(with: [0x4D, 0x4D, 0x00]) { return .tiff }
        return nil
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
