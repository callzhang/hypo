import Foundation
import HypoCore

/// Where the iOS app stores clipboard images and received files.
///
/// macOS uses the caches directory, but iOS evicts Caches under storage
/// pressure, which would silently drop images out of history. Application
/// Support inside the app container is not evicted.
///
/// Phase 3 adds a share extension and a notification service extension, at
/// which point this must point at the App Group container instead so all
/// three processes see the same files. That needs a paid developer account
/// and is deliberately out of scope here.
public struct AppContainerStorageLocations: StorageLocations {
    private let root: URL

    public init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.root = support.appendingPathComponent("com.hypo.clipboard")
    }

    public var imagesDirectory: URL {
        root.appendingPathComponent("images")
    }
}
