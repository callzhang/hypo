import Foundation

/// Where the core writes blobs — clipboard images and received files.
///
/// macOS uses the user caches directory. iOS must not: the system evicts
/// Caches under storage pressure, which would silently drop history images.
/// iOS injects an App Group container path instead.
public protocol StorageLocations: Sendable {
    var imagesDirectory: URL { get }
}

/// Default macOS behaviour: `~/Library/Caches/<bundle id>/images/`.
///
/// Matches StorageManager's historical path construction, which keys the
/// base directory off the host app's bundle identifier (falling back to
/// "com.hypo.clipboard" when one isn't available, e.g. in tests).
public struct CachesStorageLocations: StorageLocations {
    public init() {}

    public var imagesDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.hypo.clipboard"
        return caches
            .appendingPathComponent(bundleID)
            .appendingPathComponent("images")
    }
}

/// Explicit root, for tests and for the iOS App Group container.
public struct FixedStorageLocations: StorageLocations {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var imagesDirectory: URL {
        root.appendingPathComponent("images")
    }
}
