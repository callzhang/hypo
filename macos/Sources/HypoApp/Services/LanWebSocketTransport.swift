import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public struct LanWebSocketConfiguration: Sendable, Equatable {
    public let url: URL
    public let pinnedFingerprint: String?
    public let headers: [String: String]
    public let idleTimeout: TimeInterval
    public let environment: String

    public init(
        url: URL,
        pinnedFingerprint: String?,
        headers: [String: String] = [:],
        idleTimeout: TimeInterval = 30,
        environment: String = "lan"
    ) {
        self.url = url
        self.pinnedFingerprint = pinnedFingerprint
        self.headers = headers
        self.idleTimeout = idleTimeout
        self.environment = environment
    }
}

public protocol WebSocketTasking: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

extension URLSessionWebSocketTask: WebSocketTasking {}

public protocol URLSessionProviding {
    func webSocketTask(with request: URLRequest) -> WebSocketTasking
    func invalidateAndCancel()
}

extension URLSession: URLSessionProviding {
    public func webSocketTask(with request: URLRequest) -> WebSocketTasking {
        self.webSocketTask(with: request) as URLSessionWebSocketTask
    }
}

public final class LanWebSocketTransport: NSObject, SyncTransport {
    private enum ConnectionState {
        case idle
        case connecting
        case connected(WebSocketTasking)
    }

    private let configuration: LanWebSocketConfiguration
    private let sessionFactory: @Sendable (URLSessionDelegate, TimeInterval) -> URLSessionProviding
    private let frameCodec: TransportFrameCodec
    private let metricsRecorder: TransportMetricsRecorder
    private let analytics: TransportAnalytics
    private var session: URLSessionProviding?
    private var state: ConnectionState = .idle
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private var watchdogTask: Task<Void, Never>?
    private var lastActivity: Date = Date()
    private var handshakeStartedAt: Date?
    private let pendingRoundTrips = PendingRoundTripStore()

    public init(
        configuration: LanWebSocketConfiguration,
        frameCodec: TransportFrameCodec = TransportFrameCodec(),
        metricsRecorder: TransportMetricsRecorder = NullTransportMetricsRecorder(),
        analytics: TransportAnalytics = NoopTransportAnalytics(),
        sessionFactory: @escaping @Sendable (URLSessionDelegate, TimeInterval) -> URLSessionProviding = { delegate, timeout in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }
    ) {
        self.configuration = configuration
        self.frameCodec = frameCodec
        self.metricsRecorder = metricsRecorder
        self.analytics = analytics
        self.sessionFactory = sessionFactory
    }

    deinit {
        watchdogTask?.cancel()
        session?.invalidateAndCancel()
    }

    public func connect() async throws {
        switch state {
        case .connected:
            return
        case .connecting:
            try await withCheckedThrowingContinuation { continuation in
                handshakeContinuation = continuation
            }
            return
        case .idle:
            break
        }

        state = .connecting
        handshakeStartedAt = Date()
        lastActivity = Date()

        let session = sessionFactory(self, configuration.idleTimeout)
        self.session = session
        var request = URLRequest(url: configuration.url)
        configuration.headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.webSocketTask(with: request)
        state = .connecting

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            handshakeContinuation = continuation
            task.resume()
        }
    }

    public func send(_ envelope: SyncEnvelope) async throws {
        try await ensureConnected()
        guard case .connected(let task) = state else {
            throw NSError(domain: "LanWebSocketTransport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Transport not connected"])
        }
        let data = try frameCodec.encode(envelope)
        await pendingRoundTrips.store(date: Date(), for: envelope.id)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.data(data)) { [weak self] error in
                guard let self else { return }
                if let error {
                    continuation.resume(throwing: error)
                    Task { await self.pendingRoundTrips.remove(id: envelope.id) }
                } else {
                    self.touch()
                    continuation.resume(returning: ())
                }
            }
        }
    }

    public func disconnect() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        var taskToCancel: WebSocketTasking?
        switch state {
        case .connected(let task):
            taskToCancel = task
        case .connecting:
            if let continuation = handshakeContinuation {
                handshakeContinuation = nil
                continuation.resume(throwing: CancellationError())
            }
        default:
            break
        }
        state = .idle
        taskToCancel?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        handshakeStartedAt = nil
        await pendingRoundTrips.removeAll()
    }

    private func ensureConnected() async throws {
        switch state {
        case .connected:
            return
        case .idle, .connecting:
            try await connect()
        }
    }

    private func startWatchdog(for task: WebSocketTasking) {
        watchdogTask?.cancel()
        watchdogTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.configuration.idleTimeout * 1_000_000_000))
                if Task.isCancelled { return }
                let elapsed = Date().timeIntervalSince(self.lastActivity)
                if elapsed >= self.configuration.idleTimeout {
                    await self.closeDueToIdle(task: task)
                    return
                }
            }
        }
    }

    private func touch() {
        lastActivity = Date()
    }

    private func closeDueToIdle(task: WebSocketTasking) async {
        task.cancel(with: .goingAway, reason: "Idle timeout".data(using: .utf8))
        await disconnect()
    }
}

extension LanWebSocketTransport: @unchecked Sendable {}

extension LanWebSocketTransport: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        handleOpen(task: webSocketTask)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        state = .idle
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let continuation = handshakeContinuation {
            handshakeContinuation = nil
            continuation.resume(throwing: error ?? NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown))
        }
        handshakeStartedAt = nil
        state = .idle
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func receiveNext(on task: WebSocketTasking) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.touch()
                if case .data(let data) = message {
                    self.handleIncoming(data: data)
                }
                self.receiveNext(on: task)
            case .failure:
                Task { await self.disconnect() }
            }
        }
    }

    private func handleIncoming(data: Data) {
        guard let envelope = try? frameCodec.decode(data) else { return }
        Task { [metricsRecorder] in
            if let startedAt = await pendingRoundTrips.remove(id: envelope.id) {
                let duration = Date().timeIntervalSince(startedAt)
                metricsRecorder.recordRoundTrip(envelopeId: envelope.id, duration: duration)
            }
        }
    }

    func handleOpen(task: WebSocketTasking) {
        state = .connected(task)
        touch()
        startWatchdog(for: task)
        if let startedAt = handshakeStartedAt {
            let duration = Date().timeIntervalSince(startedAt)
            metricsRecorder.recordHandshake(duration: duration, timestamp: Date())
        }
        handshakeStartedAt = nil
        handshakeContinuation?.resume(returning: ())
        handshakeContinuation = nil
        receiveNext(on: task)
    }
}

extension LanWebSocketTransport: URLSessionDelegate {
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
#if canImport(Security)
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let expected = configuration.pinnedFingerprint else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverCertificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            analytics.record(
                .pinningFailure(
                    environment: configuration.environment,
                    host: configuration.url.host ?? "unknown",
                    message: "Missing server certificate",
                    timestamp: Date()
                )
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let serverData = SecCertificateCopyData(serverCertificate) as Data
        let digest = SHA256.hash(data: serverData)
        let fingerprint = digest.compactMap { String(format: "%02x", $0) }.joined()
        if fingerprint.caseInsensitiveCompare(expected) == .orderedSame {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            analytics.record(
                .pinningFailure(
                    environment: configuration.environment,
                    host: configuration.url.host ?? "unknown",
                    message: "Fingerprint mismatch",
                    timestamp: Date()
                )
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
#else
        completionHandler(.performDefaultHandling, nil)
#endif
    }
}

private actor PendingRoundTripStore {
    private var storage: [UUID: Date] = [:]

    func store(date: Date, for id: UUID) {
        storage[id] = date
    }

    func remove(id: UUID) -> Date? {
        storage.removeValue(forKey: id)
    }

    func removeAll() {
        storage.removeAll()
    }
}
