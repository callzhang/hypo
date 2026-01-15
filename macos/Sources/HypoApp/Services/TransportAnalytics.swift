import Foundation

public enum TransportFallbackReason: String, Codable {
    case lanTimeout = "lan_timeout"
    case lanRejected = "lan_rejected"
    case lanNotSupported = "lan_not_supported"
    case unknown
}

public enum TransportAnalyticsEvent: Equatable {
    case fallback(reason: TransportFallbackReason, metadata: [String: String], timestamp: Date)
    case pinningFailure(environment: String, host: String, message: String?, timestamp: Date)
    case metrics(transport: TransportChannel, snapshot: TransportMetricsSnapshot)
}

public protocol TransportAnalytics: Sendable {
    func record(_ event: TransportAnalyticsEvent)
}

public final class InMemoryTransportAnalytics: TransportAnalytics, @unchecked Sendable {
    private let queue = DispatchQueue(label: "TransportAnalytics")
    private var _events: [TransportAnalyticsEvent] = []

    public init() {}

    public func record(_ event: TransportAnalyticsEvent) {
        queue.sync {
            _events.append(event)
        }
    }

    public func events() -> [TransportAnalyticsEvent] {
        queue.sync { _events }
    }
}

public struct NoopTransportAnalytics: TransportAnalytics {
    public init() {}
    public func record(_ event: TransportAnalyticsEvent) {}
}
