import Foundation
import Testing
@testable import HypoCore

@Suite("StorageLocations")
struct StorageLocationsTests {
    @Test("injected root is used for the images directory")
    func injectedRootIsUsed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypo-storage-test-\(UUID().uuidString)")
        let locations = FixedStorageLocations(root: root)

        #expect(locations.imagesDirectory.path.hasPrefix(root.path))
    }
}
