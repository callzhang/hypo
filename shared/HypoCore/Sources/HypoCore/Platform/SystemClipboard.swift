import Foundation

/// The platform's clipboard, as the core needs it.
///
/// Covers what IncomingClipboardHandler previously did directly against
/// NSPasteboard: inspect current contents, apply a payload, and read the
/// change counter so our own writes can be told apart from the user's.
@MainActor
public protocol SystemClipboard: AnyObject {
    /// Monotonic counter the platform bumps on every clipboard change.
    var changeCount: Int { get }
    func clear()
    func writeText(_ text: String)
    /// Returns false when the data cannot be decoded as an image on this platform.
    func writeImageData(_ data: Data) -> Bool
    func writeFileURL(_ url: URL)
    func currentText() -> String?
    func containsImage() -> Bool
    /// Pixel dimensions of encoded image data, for history metadata.
    /// Returns nil when the data is not a decodable image on this platform.
    func imagePixelSize(from data: Data) -> (width: Int, height: Int)?
}

/// Test double: records every call so tests can assert against it instead
/// of touching the machine's real clipboard.
public final class RecordingClipboard: SystemClipboard {
    public private(set) var changeCount: Int = 0

    public enum Call: Equatable {
        case clear
        case writeText(String)
        case writeImageData(Data)
        case writeFileURL(URL)
        case currentText
        case containsImage
        case imagePixelSize(Data)
    }

    public private(set) var calls: [Call] = []

    /// Text returned by `currentText()`. Set directly to simulate clipboard state.
    public var textToReturn: String?
    /// Value returned by `containsImage()`.
    public var containsImageToReturn: Bool = false
    /// Whether `writeImageData(_:)` should report success.
    public var writeImageDataResult: Bool = true
    /// Value returned by `imagePixelSize(from:)`.
    public var imagePixelSizeToReturn: (width: Int, height: Int)?

    public init() {}

    public func bumpChangeCount() {
        changeCount += 1
    }

    public func clear() {
        calls.append(.clear)
        textToReturn = nil
        containsImageToReturn = false
        bumpChangeCount()
    }

    public func writeText(_ text: String) {
        calls.append(.writeText(text))
        textToReturn = text
        containsImageToReturn = false
        bumpChangeCount()
    }

    public func writeImageData(_ data: Data) -> Bool {
        calls.append(.writeImageData(data))
        if writeImageDataResult {
            textToReturn = nil
            containsImageToReturn = true
            bumpChangeCount()
        }
        return writeImageDataResult
    }

    public func writeFileURL(_ url: URL) {
        calls.append(.writeFileURL(url))
        bumpChangeCount()
    }

    public func currentText() -> String? {
        calls.append(.currentText)
        return textToReturn
    }

    public func containsImage() -> Bool {
        calls.append(.containsImage)
        return containsImageToReturn
    }

    public func imagePixelSize(from data: Data) -> (width: Int, height: Int)? {
        calls.append(.imagePixelSize(data))
        return imagePixelSizeToReturn
    }
}
