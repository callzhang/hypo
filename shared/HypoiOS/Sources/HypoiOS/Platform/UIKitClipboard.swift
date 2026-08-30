import Foundation
import UIKit
import HypoCore

/// iOS implementation of SystemClipboard, backed by UIPasteboard.
///
/// This object answers reads about content it wrote itself, and never reads
/// content it did not write. `currentText()` returns nil and `containsImage()`
/// returns false once anything else has written to the pasteboard.
///
/// That is a deliberate narrowing of the protocol, for two reasons.
///
/// `-[UIPasteboard string]` blocks the calling thread on a semaphore while the
/// pasteboard server produces the item, and `SystemClipboard` is `@MainActor`,
/// so there is no thread to move the call off. Sampling a hung test process
/// showed the main thread parked in `semaphore_wait_trap` under
/// `_UIConcretePasteboard string` with no way forward. On iOS 16+ that wait can
/// also be gated on the system paste prompt, which needs a foreground app to
/// present it.
///
/// And the only caller that reads is `IncomingClipboardHandler`, which compares
/// incoming payloads against the current clipboard purely to suppress echoes.
/// Echo suppression only ever concerns content this app just wrote, which the
/// cache answers exactly. For anything else, reading would block the main
/// thread and raise a paste prompt the user did not ask for, in the middle of a
/// background sync — to decide a question whose safe answer is already "no
/// match, apply it".

@MainActor
public final class UIKitClipboard: SystemClipboard {
    private let pasteboard: UIPasteboard

    /// What we last wrote, and the change count the pasteboard reported
    /// immediately afterwards. A different change count means somebody else
    /// has written since, so the cache no longer describes the pasteboard and
    /// reads report "unknown" rather than interrogating the system.
    private var lastWrittenText: String?
    private var lastWrittenIsImage = false
    private var lastWrittenChangeCount: Int?

    public init(pasteboard: UIPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func clear() {
        pasteboard.items = []
        recordWrite(text: nil, isImage: false)
    }

    public func writeText(_ text: String) {
        pasteboard.string = text
        recordWrite(text: text, isImage: false)
    }

    public func writeImageData(_ data: Data) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        pasteboard.image = image
        recordWrite(text: nil, isImage: true)
        return true
    }

    public func writeFileURL(_ url: URL) {
        pasteboard.url = url
        recordWrite(text: url.absoluteString, isImage: false)
    }

    public func currentText() -> String? {
        cacheIsCurrent ? lastWrittenText : nil
    }

    public func containsImage() -> Bool {
        cacheIsCurrent ? lastWrittenIsImage : false
    }

    /// Reads text this app did not write, for sending it on.
    ///
    /// `currentText()` deliberately refuses to do this: it answers echo
    /// suppression questions, where reading foreign content would block the
    /// main thread and raise a paste prompt for no reason the user asked for.
    /// Sending is the opposite case — the user opened the app expecting what
    /// they copied to go somewhere, so the prompt is the price of the feature,
    /// the same read Android does in onResume.
    ///
    /// Returns nil when this object was the last writer, which means nothing
    /// new has been copied and sending would echo back what just arrived.
    ///
    /// Loads through NSItemProvider rather than `pasteboard.string`, which
    /// blocks the calling thread on a semaphore while the pasteboard server
    /// produces the item — the read that deadlocked before.
    public func readForegroundText() async -> String? {
        guard !cacheIsCurrent else { return nil }
        guard let provider = pasteboard.itemProviders.first,
              provider.canLoadObject(ofClass: NSString.self) else { return nil }

        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: object as? String)
            }
        }
    }

    public func imagePixelSize(from data: Data) -> (width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        // UIImage reports points; multiplying by scale gives pixels, which is
        // what NSImage.size already reports for a PNG on macOS. Both platforms
        // then record the same dimensions in history metadata.
        return (width: Int(image.size.width * image.scale),
                height: Int(image.size.height * image.scale))
    }

    private var cacheIsCurrent: Bool {
        guard let recorded = lastWrittenChangeCount else { return false }
        return pasteboard.changeCount == recorded
    }

    private func recordWrite(text: String?, isImage: Bool) {
        lastWrittenText = text
        lastWrittenIsImage = isImage
        lastWrittenChangeCount = pasteboard.changeCount
    }
}
