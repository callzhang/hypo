import Foundation

/// Multicast event dispatcher for clipboard events
@MainActor
public final class ClipboardEventDispatcher {
    private var clipboardAppliedHandlers: [(Int) -> Void] = []
    private var clipboardReceivedHandlers: [(String, Date) -> Void] = []
    
    public init() {}
    
    public func addClipboardAppliedHandler(_ handler: @escaping (Int) -> Void) {
        clipboardAppliedHandlers.append(handler)
    }
    
    public func addClipboardReceivedHandler(_ handler: @escaping (String, Date) -> Void) {
        clipboardReceivedHandlers.append(handler)
    }
    
    public func notifyClipboardApplied(changeCount: Int) {
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
