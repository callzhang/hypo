import Foundation
import Testing
@testable import HypoiOS

@Suite("HypoiOS package wiring")
struct PackageSmokeTests {
    @Test("HypoiOS can read a HypoCore constant")
    func readsCoreConstant() {
        #expect(HypoiOS.maxAttachmentBytes == 10 * 1024 * 1024)
    }
}
