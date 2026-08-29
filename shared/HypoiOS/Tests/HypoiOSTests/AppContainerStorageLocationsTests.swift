import Foundation
import Testing
import HypoCore
@testable import HypoiOS

@Suite("AppContainerStorageLocations")
struct AppContainerStorageLocationsTests {
    @Test("images directory sits under Application Support, not Caches")
    func usesApplicationSupport() {
        let locations = AppContainerStorageLocations()
        let path = locations.imagesDirectory.path

        #expect(path.contains("Application Support"))
        #expect(!path.contains("Caches"))
    }

    @Test("images directory can be created")
    func createsDirectory() throws {
        let locations = AppContainerStorageLocations()

        try FileManager.default.createDirectory(
            at: locations.imagesDirectory,
            withIntermediateDirectories: true
        )

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: locations.imagesDirectory.path,
            isDirectory: &isDirectory
        )
        #expect(exists)
        #expect(isDirectory.boolValue)
    }
}
