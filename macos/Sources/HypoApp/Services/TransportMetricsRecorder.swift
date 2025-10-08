import Foundation

public protocol TransportMetricsRecorder {
    func recordHandshake(duration: TimeInterval, timestamp: Date)
    func recordRoundTrip(envelopeId: UUID, duration: TimeInterval)
}

public struct NullTransportMetricsRecorder: TransportMetricsRecorder {
    public init() {}

    public func recordHandshake(duration: TimeInterval, timestamp: Date) {}

    public func recordRoundTrip(envelopeId: UUID, duration: TimeInterval) {}
}

public struct TransportMetricDistribution: Equatable {
    public let samples: [Double]
    public let p50: Double
    public let p90: Double
    public let p95: Double
}

public struct TransportMetricsSnapshot: Equatable {
    public let generatedAt: Date
    public let environment: String
    public let handshake: TransportMetricDistribution?
    public let roundTrip: TransportMetricDistribution?
}

public final class TransportMetricsAggregator: TransportMetricsRecorder {
    private let lock = NSLock()
    private var handshakeDurationsMs: [Double] = []
    private var roundTripDurationsMs: [Double] = []
    private let environment: String
    private let dateProvider: () -> Date

    public init(environment: String, dateProvider: @escaping () -> Date = Date.init) {
        self.environment = environment
        self.dateProvider = dateProvider
    }

    public func recordHandshake(duration: TimeInterval, timestamp: Date) {
        let millis = duration * 1_000
        lock.withLock {
            handshakeDurationsMs.append(millis)
        }
    }

    public func recordRoundTrip(envelopeId: UUID, duration: TimeInterval) {
        let millis = duration * 1_000
        lock.withLock {
            roundTripDurationsMs.append(millis)
        }
    }

    public func snapshot(clear: Bool = false) -> TransportMetricsSnapshot? {
        var handshakes: [Double] = []
        var roundTrips: [Double] = []
        lock.withLock {
            handshakes = handshakeDurationsMs
            roundTrips = roundTripDurationsMs
            if clear {
                handshakeDurationsMs.removeAll()
                roundTripDurationsMs.removeAll()
            }
        }
        if handshakes.isEmpty && roundTrips.isEmpty {
            return nil
        }
        return TransportMetricsSnapshot(
            generatedAt: dateProvider(),
            environment: environment,
            handshake: distribution(from: handshakes),
            roundTrip: distribution(from: roundTrips)
        )
    }

    public func publish(transport: TransportChannel, analytics: TransportAnalytics) {
        guard let snapshot = snapshot(clear: true) else { return }
        analytics.record(.metrics(transport: transport, snapshot: snapshot))
    }

    private func distribution(from samples: [Double]) -> TransportMetricDistribution? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return TransportMetricDistribution(
            samples: sorted,
            p50: percentile(sorted, percentile: 0.50),
            p90: percentile(sorted, percentile: 0.90),
            p95: percentile(sorted, percentile: 0.95)
        )
    }

    private func percentile(_ sorted: [Double], percentile: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        guard sorted.count > 1 else { return sorted.first ?? .nan }
        let rank = Int(ceil(percentile * Double(sorted.count))).clamped(to: 1...sorted.count)
        return sorted[rank - 1]
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        if self < range.lowerBound { return range.lowerBound }
        if self > range.upperBound { return range.upperBound }
        return self
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
