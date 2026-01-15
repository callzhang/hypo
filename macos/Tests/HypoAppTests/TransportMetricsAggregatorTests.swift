import Foundation
import Testing
@testable import HypoApp

struct TransportMetricsAggregatorTests {
    @Test
    func testPublishRecordsMetricsEvent() {
        let analytics = InMemoryTransportAnalytics()
        let date = Date(timeIntervalSince1970: 0)
        let aggregator = TransportMetricsAggregator(environment: "loopback", dateProvider: { date })

        recordHandshakeSamples(aggregator: aggregator)
        recordRoundTripSamples(aggregator: aggregator)

        aggregator.publish(transport: TransportChannel.lan, analytics: analytics)

        let events = analytics.events()
        #expect(events.count == 1)
        guard case let .metrics(transport, snapshot) = events.first else {
            #expect(false)
            return
        }
        #expect(transport == .lan)
        #expect(snapshot.environment == "loopback")
        #expect(snapshot.handshake?.samples.count == 5)
        expectApproxEqual(snapshot.handshake?.p95 ?? 0, 44.2, tolerance: 0.05)
        expectApproxEqual(snapshot.roundTrip?.p95 ?? 0, 16.2, tolerance: 0.05)

        #expect(aggregator.snapshot() == nil)
    }

    @Test
    func testSnapshotNilWhenEmpty() {
        let analytics = InMemoryTransportAnalytics()
        let aggregator = TransportMetricsAggregator(environment: "loopback")
        #expect(aggregator.snapshot() == nil)
        aggregator.publish(transport: TransportChannel.cloud, analytics: analytics)
        #expect(analytics.events().isEmpty)
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
