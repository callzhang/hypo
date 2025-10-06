import XCTest
@testable import HypoApp

final class BonjourBrowserTests: XCTestCase {
    func testEventsStreamPublishesAddAndRemove() async throws {
        let driver = MockBonjourDriver()
        var now = Date(timeIntervalSince1970: 1_000)
        let browser = BonjourBrowser(driver: driver, clock: { now })
        let stream = await browser.events()
        await browser.start()

        let task = Task { () -> [LanDiscoveryEvent] in
            var iterator = stream.makeAsyncIterator()
            var events: [LanDiscoveryEvent] = []
            for _ in 0..<2 {
                if let event = await iterator.next() {
                    events.append(event)
                }
            }
            return events
        }

        let record = BonjourServiceRecord(
            serviceName: "peer-one",
            host: "mac.local",
            port: 7010,
            txtRecords: ["fingerprint_sha256": "abc", "protocols": "ws+tls"]
        )
        driver.emit(.resolved(record))
        _ = await waitForPeerCount(browser, expected: 1)
        now = now.addingTimeInterval(5)
        driver.emit(.removed("peer-one"))

        let events = await task.value
        XCTAssertEqual(events.count, 2)
        if case .added(let peer) = events[0] {
            XCTAssertEqual(peer.serviceName, "peer-one")
            XCTAssertEqual(peer.endpoint.host, "mac.local")
            XCTAssertEqual(peer.endpoint.port, 7010)
            XCTAssertEqual(peer.endpoint.fingerprint, "abc")
            XCTAssertEqual(peer.lastSeen, Date(timeIntervalSince1970: 1_000))
        } else {
            XCTFail("Expected added event")
        }
        if case .removed(let serviceName) = events[1] {
            XCTAssertEqual(serviceName, "peer-one")
        } else {
            XCTFail("Expected removed event")
        }

        await browser.stop()
    }

    func testPrunePeersRemovesStaleEntries() async throws {
        let driver = MockBonjourDriver()
        var now = Date(timeIntervalSince1970: 1_000)
        let browser = BonjourBrowser(driver: driver, clock: { now })
        await browser.start()

        let record = BonjourServiceRecord(
            serviceName: "stale-peer",
            host: "mac.local",
            port: 7010,
            txtRecords: [:]
        )
        driver.emit(.resolved(record))
        _ = await waitForPeerCount(browser, expected: 1)

        now = now.addingTimeInterval(20)
        let removed = await browser.prunePeers(olderThan: 10)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.serviceName, "stale-peer")
        let peers = await browser.currentPeers()
        XCTAssertTrue(peers.isEmpty)
        await browser.stop()
    }
}

private final class MockBonjourDriver: BonjourBrowsingDriver {
    private var handler: ((BonjourBrowsingDriverEvent) -> Void)?
    private(set) var startCount = 0

    func startBrowsing(serviceType: String, domain: String) {
        startCount += 1
    }

    func stopBrowsing() {
        startCount = max(0, startCount - 1)
    }

    func setEventHandler(_ handler: @escaping (BonjourBrowsingDriverEvent) -> Void) {
        self.handler = handler
    }

    func emit(_ event: BonjourBrowsingDriverEvent) {
        handler?(event)
    }
}

private func waitForPeerCount(
    _ browser: BonjourBrowser,
    expected: Int,
    retries: Int = 10,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> [DiscoveredPeer] {
    for attempt in 0..<retries {
        let peers = await browser.currentPeers()
        if peers.count == expected {
            return peers
        }
        if attempt < retries - 1 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    XCTFail("Timed out waiting for expected peer count \(expected)", file: file, line: line)
    return await browser.currentPeers()
}
