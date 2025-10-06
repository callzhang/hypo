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
