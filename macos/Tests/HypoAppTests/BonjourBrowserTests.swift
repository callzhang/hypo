import Foundation
import Testing
@testable import HypoApp

struct BonjourBrowserTests {
    @Test @MainActor
    func testEventsStreamPublishesAddAndRemove() async throws {
        let driver = MockBonjourDriver()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000))
        let browser = await MainActor.run { BonjourBrowser(driver: driver, clock: { clock.now }) }
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
        clock.now = clock.now.addingTimeInterval(5)
        driver.emit(.removed("peer-one"))

        let events = await task.value
        #expect(events.count == 2)
        if case .added(let peer) = events[0] {
            #expect(peer.serviceName == "peer-one")
            #expect(peer.endpoint.host == "mac.local")
            #expect(peer.endpoint.port == 7010)
            #expect(peer.lastSeen == Date(timeIntervalSince1970: 1_000))
        } else {
            #expect(Bool(false))
        }
        if case .removed(let serviceName) = events[1] {
            #expect(serviceName == "peer-one")
        } else {
            #expect(Bool(false))
        }

        await browser.stop()
    }

    @Test @MainActor
    func testPrunePeersRemovesStaleEntries() async throws {
        let driver = MockBonjourDriver()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_000))
        let browser = await MainActor.run { BonjourBrowser(driver: driver, clock: { clock.now }) }
        await browser.start()

        let record = BonjourServiceRecord(
            serviceName: "stale-peer",
            host: "mac.local",
            port: 7010,
            txtRecords: [:]
        )
        driver.emit(.resolved(record))
        _ = await waitForPeerCount(browser, expected: 1)

        clock.now = clock.now.addingTimeInterval(20)
        let removed = await browser.prunePeers(olderThan: 10)
        #expect(removed.count == 1)
        #expect(removed.first?.serviceName == "stale-peer")
        let peers = await browser.currentPeers()
        #expect(peers.isEmpty)
        await browser.stop()
    }
}

@MainActor


private func waitForPeerCount(
    _ browser: BonjourBrowser,
    expected: Int,
    retries: Int = 10
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
    let peers = await browser.currentPeers()
    #expect(peers.count == expected)
    return peers
}
