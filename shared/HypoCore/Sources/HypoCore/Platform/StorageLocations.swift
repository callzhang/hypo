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

/// Where the app stores clipboard images and received files on iOS.
///
/// iOS evicts Caches under storage pressure, which would silently drop images
/// out of history — the entries survive, the files they point at do not.
/// Application Support inside the app container is not evicted.
///
/// Phase 3 adds a share extension and a notification service extension, at
/// which point this must point at the App Group container instead so all three
/// processes see the same files. That needs a paid developer account and is
/// deliberately out of scope for now.
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

/// The storage locations appropriate to the platform this build runs on.
///
/// macOS stays on Caches so existing installs keep finding what they already
/// wrote there. iOS uses the app container, because Caches is evictable.
public enum PlatformStorageLocations {
    public static func current() -> StorageLocations {
        #if os(iOS)
        AppContainerStorageLocations()
        #else
        CachesStorageLocations()
        #endif
    }
}
