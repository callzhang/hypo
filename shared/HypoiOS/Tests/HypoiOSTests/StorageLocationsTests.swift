import Foundation
import Testing
import HypoCore

@Suite("Storage locations on iOS")
struct StorageLocationsTests {
    @Test("the platform default is the app container, not caches")
    func platformDefaultIsAppContainer() {
        // StorageManager.shared takes this default. When AppContainerStorageLocations
        // lived in HypoiOS, nothing could reach it from HypoCore, so the singleton
        // silently kept using Caches — which iOS evicts under storage pressure,
        // leaving history entries pointing at files that no longer exist.
        let path = PlatformStorageLocations.current().imagesDirectory.path

        #expect(path.contains("Application Support"))
        #expect(!path.contains("Caches"))
    }

    @Test("the shared StorageManager resolves to the app container")
    @MainActor
    func sharedManagerUsesAppContainer() {
        // The assertion that matters: not what the platform default returns,
        // but what the singleton every caller goes through actually resolved to.
        let path = StorageManager.shared.imagesDirectoryURL.path

        #expect(path.contains("Application Support"))
        #expect(!path.contains("Caches"))
    }

    @Test("the images directory can actually be created")
    func imagesDirectoryIsCreatable() throws {
        let directory = PlatformStorageLocations.current().imagesDirectory

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
