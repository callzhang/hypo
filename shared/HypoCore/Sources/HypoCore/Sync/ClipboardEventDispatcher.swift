import Foundation

/// Multicast event dispatcher for clipboard events
@MainActor
public final class ClipboardEventDispatcher {
    private var clipboardAppliedHandlers: [(Int) -> Void] = []
    /// Handlers that also want to know *what* was applied, not just that something was.
    private var clipboardAppliedContentHandlers: [(String) -> Void] = []
    private var clipboardReceivedHandlers: [(String, Date) -> Void] = []
    
    public init() {}
    
    /// Called with a fingerprint of content this device just applied from a peer.
    /// A capture that matches it is that same content coming back, not a new copy.
    public func addClipboardAppliedContentHandler(_ handler: @escaping (String) -> Void) {
        clipboardAppliedContentHandlers.append(handler)
    }

    public func addClipboardAppliedHandler(_ handler: @escaping (Int) -> Void) {
        clipboardAppliedHandlers.append(handler)
    }
    
    public func addClipboardReceivedHandler(_ handler: @escaping (String, Date) -> Void) {
        clipboardReceivedHandlers.append(handler)
    }
    
    public func notifyClipboardApplied(changeCount: Int, fingerprint: String? = nil) {
        if let fingerprint {
            for handler in clipboardAppliedContentHandlers {
                handler(fingerprint)
            }
        }
        notifyClipboardAppliedCount(changeCount)
    }

    private func notifyClipboardAppliedCount(_ changeCount: Int) {
        for handler in clipboardAppliedHandlers {
            handler(changeCount)
        }
    }
    
    public func notifyClipboardReceived(deviceId: String, timestamp: Date) {
        for handler in clipboardReceivedHandlers {
            handler(deviceId, timestamp)
        }
    }
}
