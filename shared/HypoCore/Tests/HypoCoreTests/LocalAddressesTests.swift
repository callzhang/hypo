import Foundation
import Testing
@testable import HypoCore

struct LocalAddressesTests {
    @Test
    func testKnowsItsOwnLoopback() {
        let addresses = LocalAddresses.current()
        #expect(LocalAddresses.isLocal("127.0.0.1", addresses: addresses))
        #expect(LocalAddresses.isLocal("::1", addresses: addresses))
    }

    @Test
    func testAPeerOnAnotherMachineIsNotLocal() {
        // A private address that is not ours: the point of the check is that a real
        // peer keeps being offered.
        let addresses: Set<String> = ["127.0.0.1", "10.0.0.252"]
        #expect(LocalAddresses.isLocal("10.0.0.17", addresses: addresses) == false)
    }

    @Test
    func testMatchesOurOwnLanAddress() {
        let addresses: Set<String> = ["127.0.0.1", "10.0.0.252"]
        #expect(LocalAddresses.isLocal("10.0.0.252", addresses: addresses))
    }

    @Test
    func testIgnoresCasingAndIPv6Zones() {
        let addresses: Set<String> = ["fe80::1c2b:3d4e"]
        #expect(LocalAddresses.isLocal("FE80::1C2B:3D4E%en0", addresses: addresses))
    }
}
