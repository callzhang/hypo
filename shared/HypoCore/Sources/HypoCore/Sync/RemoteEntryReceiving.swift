import Foundation

/// Receives clipboard entries that arrived from a paired device.
///
/// The transport layer needs to hand incoming entries to whatever presents
/// history, without knowing what that is. On macOS it is the menu bar's
/// view model; on iOS it will be something else entirely.
@MainActor
public protocol RemoteEntryReceiving: AnyObject {
    func handleIncomingRemoteEntry(_ entry: ClipboardEntry, duplicate: ClipboardEntry?) async
}
