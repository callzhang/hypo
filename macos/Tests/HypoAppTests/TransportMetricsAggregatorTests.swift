import XCTest
@testable import HypoApp

final class TransportMetricsAggregatorTests: XCTestCase {
    func testPublishRecordsMetricsEvent() {
        let analytics = InMemoryTransportAnalytics()
        let date = Date(timeIntervalSince1970: 0)
        let aggregator = TransportMetricsAggregator(environment: "loopback", dateProvider: { date })

        recordHandshakeSamples(aggregator: aggregator)
        recordRoundTripSamples(aggregator: aggregator)

        aggregator.publish(transport: .lan, analytics: analytics)

        let events = analytics.events()
        XCTAssertEqual(1, events.count)
        guard case let .metrics(transport, snapshot) = events.first else {
            XCTFail("Expected metrics event")
            return
        }
        XCTAssertEqual(.lan, transport)
        XCTAssertEqual("loopback", snapshot.environment)
        XCTAssertEqual(5, snapshot.handshake?.samples.count)
        XCTAssertEqual(snapshot.handshake?.p95 ?? 0, 44.2, accuracy: 0.05)
        XCTAssertEqual(snapshot.roundTrip?.p95 ?? 0, 16.2, accuracy: 0.05)

        XCTAssertNil(aggregator.snapshot())
    }

    func testSnapshotNilWhenEmpty() {
        let analytics = InMemoryTransportAnalytics()
        let aggregator = TransportMetricsAggregator(environment: "loopback")
        XCTAssertNil(aggregator.snapshot())
        aggregator.publish(transport: .cloud, analytics: analytics)
        XCTAssertTrue(analytics.events().isEmpty)
    }

    private func recordHandshakeSamples(aggregator: TransportMetricsAggregator) {
        [42.0, 41.5, 44.2, 39.8, 42.7].forEach { value in
            aggregator.recordHandshake(duration: value / 1_000, timestamp: Date())
        }
    }

    private func recordRoundTripSamples(aggregator: TransportMetricsAggregator) {
        [15.0, 14.5, 16.2, 13.8, 15.3].forEach { value in
            aggregator.recordRoundTrip(envelopeId: UUID().uuidString, duration: value / 1_000)
        }
    }
}
