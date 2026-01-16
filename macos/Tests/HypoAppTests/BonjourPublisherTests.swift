#if canImport(Darwin)
import Foundation
import Testing
@testable import HypoApp

@MainActor
struct BonjourPublisherTests {
    @Test
    func testStartUsesFactoryAndPublishes() {
        let mockService = MockNetService(domain: "local.", type: "_hypo._tcp.", name: "test", port: 5555)
        let publisher = BonjourPublisher(netServiceFactory: { _, _, _, _ in mockService })
        let config = BonjourPublisher.Configuration(
            serviceName: "test",
            port: 5555,
            version: "1.0",
            fingerprint: "fp",
            protocols: ["ws"]
        )

        publisher.start(with: config)

        #expect(mockService.publishCount == 1)
        #expect(mockService.setTXTRecordCount == 1)
        #expect(mockService.includesPeerToPeer)
        #expect(publisher.currentConfiguration?.serviceName == "test")
    }

    @Test
    func testStartSkipsWhenPortInvalid() {
        let factoryCalled = Locked(false)
        let publisher = BonjourPublisher(netServiceFactory: { _, _, _, _ in
            factoryCalled.withLock { $0 = true }
            return MockNetService(domain: "local.", type: "_hypo._tcp.", name: "test", port: 0)
        })
        let config = BonjourPublisher.Configuration(
            serviceName: "test",
            port: 0,
            version: "1.0",
            fingerprint: "fp",
            protocols: ["ws"]
        )

        publisher.start(with: config)
        #expect(factoryCalled.withLock { $0 } == false)
    }

    @Test
    func testUpdateTXTRecordNoServiceNoOp() {
        let publisher = BonjourPublisher()
        publisher.updateTXTRecord(["version": "1.0"])
        #expect(publisher.currentConfiguration == nil)
    }

    @Test
    func testStopCompletionFiresOnDidStop() {
        let mockService = MockNetService(domain: "local.", type: "_hypo._tcp.", name: "test", port: 5555)
        let publisher = BonjourPublisher(netServiceFactory: { _, _, _, _ in mockService })
        let config = BonjourPublisher.Configuration(
            serviceName: "test",
            port: 5555,
            version: "1.0",
            fingerprint: "fp",
            protocols: ["ws"]
        )
        publisher.start(with: config)

        var didStop = false
        publisher.stop {
            didStop = true
        }

        publisher.netServiceDidStop(mockService)
        #expect(didStop)
        #expect(publisher.currentConfiguration != nil)
    }

    @Test
    func testCurrentEndpointIncludesMetadata() {
        let mockService = MockNetService(domain: "local.", type: "_hypo._tcp.", name: "test", port: 5555)
        let publisher = BonjourPublisher(netServiceFactory: { _, _, _, _ in mockService })
        let config = BonjourPublisher.Configuration(
            serviceName: "test",
            port: 5555,
            version: "1.2.3",
            fingerprint: "fp",
            protocols: ["ws", "wss"],
            deviceId: "device-1",
            publicKey: "pub",
            signingPublicKey: "signing"
        )

        publisher.start(with: config)

        let endpoint = publisher.currentEndpoint
        #expect(endpoint?.deviceId == "device-1")
        #expect(endpoint?.fingerprint == "fp")
        #expect(endpoint?.metadata["pub_key"] == "pub")
        #expect(endpoint?.metadata["signing_pub_key"] == "signing")
    }

    @Test
    func testStopCompletionWhenServiceMissing() {
        let publisher = BonjourPublisher()

        var didStop = false
        publisher.stop {
            didStop = true
        }
        #expect(didStop)
    }

    @Test
    func testNetServiceDelegateCallbacks() {
        let mockService = MockNetService(domain: "local.", type: "_hypo._tcp.", name: "test", port: 5555)
        let publisher = BonjourPublisher(netServiceFactory: { _, _, _, _ in mockService })
        let config = BonjourPublisher.Configuration(
            serviceName: "test",
            port: 5555,
            version: "1.0",
            fingerprint: "fp",
            protocols: ["ws"]
        )

        publisher.start(with: config)
        publisher.netServiceDidPublish(mockService)
        publisher.netService(mockService, didNotPublish: ["code": 1])
    }
}

final class MockNetService: NetService, @unchecked Sendable {
    private(set) var publishCount = 0
    private(set) var stopCount = 0
    private(set) var setTXTRecordCount = 0

    override func publish() {
        publishCount += 1
    }

    override func stop() {
        stopCount += 1
    }

    override func setTXTRecord(_ recordData: Data?) -> Bool {
        setTXTRecordCount += 1
        return true
    }
}
#endif
