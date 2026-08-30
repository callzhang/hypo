import Foundation
import UIKit
import Testing
import HypoCore
@testable import HypoiOS

@Suite("UIKitClipboard", .serialized)
struct UIKitClipboardTests {
    @Test("writeText then currentText round-trips")
    @MainActor
    func textRoundTrips() {
        let clipboard = UIKitClipboard()

        clipboard.clear()
        clipboard.writeText("hello from test")

        // Served from the write-through cache. Reading through to UIPasteboard
        // here used to deadlock: the read blocks the main thread on a semaphore
        // while the change notification from the write above is still being
        // delivered, and that delivery needs the main thread.
        #expect(clipboard.currentText() == "hello from test")
    }

    @Test("changeCount increases after a write")
    @MainActor
    func changeCountAdvances() {
        let clipboard = UIKitClipboard()
        let before = clipboard.changeCount
        clipboard.writeText("bump")
        #expect(clipboard.changeCount > before)
    }

    @Test("imagePixelSize returns nil for non-image data")
    @MainActor
    func pixelSizeNilForGarbage() {
        let clipboard = UIKitClipboard()
        #expect(clipboard.imagePixelSize(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test("imagePixelSize reports pixels, not points")
    @MainActor
    func pixelSizeForRealImage() {
        // Render at scale 1 explicitly. UIGraphicsImageRenderer otherwise uses
        // the screen's scale, so a 7x3 request yields a 21x9 pixel image on a
        // 3x simulator and the expected numbers would depend on the device.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 7, height: 3),
            format: format
        )
        let png = renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 7, height: 3))
        }
        let clipboard = UIKitClipboard()

        let size = clipboard.imagePixelSize(from: png)

        // Pixels, matching what NSImage.size reports for a PNG on macOS, so
        // both platforms record the same dimensions in history metadata.
        #expect(size?.width == 7)
        #expect(size?.height == 3)
    }

    @Test("containsImage is false after writing text")
    @MainActor
    func containsImageFalseForText() {
        let clipboard = UIKitClipboard()
        clipboard.clear()
        clipboard.writeText("not an image")
        #expect(clipboard.containsImage() == false)
    }

    @Test("containsImage is true after writing an image")
    @MainActor
    func containsImageTrueForImage() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2),
            format: format
        )
        let png = renderer.pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let clipboard = UIKitClipboard()

        clipboard.clear()
        #expect(clipboard.writeImageData(png))
        #expect(clipboard.containsImage())
        #expect(clipboard.currentText() == nil)
    }

    @Test("a write from outside makes reads report unknown")
    @MainActor
    func foreignWriteInvalidatesCache() {
        let clipboard = UIKitClipboard()

        clipboard.writeText("ours")
        #expect(clipboard.currentText() == "ours")

        // Write behind the object's back, the way another app would. The
        // change count no longer matches what was recorded, so the clipboard
        // reports "unknown" rather than reading content it did not write —
        // which would block the main thread and raise a paste prompt.
        UIPasteboard.general.string = "theirs"

        #expect(clipboard.currentText() == nil)
        #expect(clipboard.containsImage() == false)
    }

    @Test("nothing is offered for sending when we wrote the contents ourselves")
    @MainActor
    func foregroundReadSkipsOurOwnWrites() async {
        let clipboard = UIKitClipboard()

        clipboard.writeText("something that just arrived from a peer")

        // Returns before touching the pasteboard, which is what stops an entry
        // that just arrived from being sent straight back to the device it
        // came from.
        #expect(await clipboard.readForegroundText() == nil)
    }

    // The other branch — reading content another app wrote — cannot be
    // exercised here. A test bundle has no host app, so the pasteboard read
    // waits on a prompt that has nowhere to appear and never returns. It is
    // covered by running the app.
}
