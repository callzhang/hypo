import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Models

public struct LanEndpoint: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let deviceId: String?
    public let deviceName: String?
    public let fingerprint: String?
    public let metadata: [String: String]

    public init(host: String, port: Int, deviceId: String? = nil, deviceName: String? = nil, fingerprint: String? = nil, metadata: [String: String] = [:]) {
        self.host = host
        self.port = port
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.fingerprint = fingerprint
        self.metadata = metadata
    }
}

/// How long to wait before trying a failed Bonjour browse again.
///
/// A browse that fails is not retried by the system. At login the network is
/// often not up yet, so the first attempt fails and, without this, the app spends
/// the rest of the session unable to see anything on the LAN.
public struct BrowseRetryPolicy: Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(initialDelay: TimeInterval = 1, maximumDelay: TimeInterval = 30) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
    }

    /// `attempt` counts from 1 for the first retry.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return initialDelay }
        let doubled = initialDelay * pow(2, Double(attempt - 1))
        return min(doubled, maximumDelay)
    }
}

/// Decodes a DNS-SD TXT record.
///
/// `NetService.dictionary(fromTXTRecord:)` is typed `[String: Data]` in Swift, but
/// the record format allows an entry to be a bare key with no value, and that
/// bridges as `NSNull`. The forced bridge inside that call then aborts the whole
/// process -- a peer advertising one valueless key crashes anything that resolves
/// it. Parsing the bytes ourselves is a dozen lines and cannot fail that way.
public enum TXTRecord {
    public static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            let entryStart = data.index(after: index)
            guard length > 0, let entryEnd = data.index(entryStart, offsetBy: length, limitedBy: data.endIndex) else {
                // A length that runs past the end means the record is malformed;
                // keep whatever parsed cleanly rather than discarding all of it.
                break
            }
            let entry = data[entryStart..<entryEnd]
            if let separator = entry.firstIndex(of: UInt8(ascii: "=")) {
                let key = String(decoding: entry[entry.startIndex..<separator], as: UTF8.self)
                let value = String(decoding: entry[entry.index(after: separator)...], as: UTF8.self)
                if !key.isEmpty { result[key] = value }
            } else {
                // A key with no value is legal and means "present".
                let key = String(decoding: entry, as: UTF8.self)
                if !key.isEmpty { result[key] = "" }
            }
            index = entryEnd
        }
        return result
    }
}

public struct DiscoveredPeer: Equatable, Sendable {
    public let serviceName: String
    public let endpoint: LanEndpoint
    public let lastSeen: Date

    public init(serviceName: String, endpoint: LanEndpoint, lastSeen: Date) {
        self.serviceName = serviceName
        self.endpoint = endpoint
        self.lastSeen = lastSeen
    }
}

public enum LanDiscoveryEvent: Equatable, Sendable {
    case added(DiscoveredPeer)
    case removed(String)
}

public struct BonjourServiceRecord: Equatable, Sendable {
    public let serviceName: String
    public let host: String
    public let port: Int
    public let txtRecords: [String: String]

    public init(serviceName: String, host: String, port: Int, txtRecords: [String: String]) {
        self.serviceName = serviceName
        self.host = host
        self.port = port
        self.txtRecords = txtRecords
    }
}

public enum BonjourBrowsingDriverEvent: Equatable, Sendable {
    case resolved(BonjourServiceRecord)
    case removed(String)
}

// MARK: - Driver Protocol

public protocol BonjourBrowsingDriver: AnyObject, Sendable {
    @MainActor func startBrowsing(serviceType: String, domain: String)
    @MainActor func stopBrowsing()
    @MainActor func setEventHandler(_ handler: @escaping @Sendable (BonjourBrowsingDriverEvent) -> Void)
}

// MARK: - BonjourBrowser Actor

public actor BonjourBrowser {
    private let serviceType: String
    private let domain: String
    private let driver: BonjourBrowsingDriver
    private let clock: @Sendable () -> Date
    private let driverEventStream: AsyncStream<BonjourBrowsingDriverEvent>
    private let driverEventContinuation: AsyncStream<BonjourBrowsingDriverEvent>.Continuation

    private var continuations: [UUID: AsyncStream<LanDiscoveryEvent>.Continuation] = [:]
    private var peers: [String: DiscoveredPeer] = [:]
    private var didStart = false
    private var driverEventTask: Task<Void, Never>?

    @MainActor
    public init(
        serviceType: String = "_hypo._tcp.",
        domain: String = "local.",
        driver: BonjourBrowsingDriver? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        var continuation: AsyncStream<BonjourBrowsingDriverEvent>.Continuation!
        self.driverEventStream = AsyncStream { continuation = $0 }
        self.driverEventContinuation = continuation
        self.serviceType = serviceType
        self.domain = domain
        self.driver = driver ?? NetServiceBonjourBrowsingDriver()
        self.clock = clock
        
        // Use a detached task to avoid capturing 'self' before it's fully initialized
        // and to bridge to @MainActor for driver setup
        let d = self.driver
        let continuationToCapture = self.driverEventContinuation
        Task { @MainActor in
            d.setEventHandler { event in
                continuationToCapture.yield(event)
            }
        }
    }

    deinit {
        let d = driver
        Task { @MainActor in
            d.stopBrowsing()
        }
        driverEventTask?.cancel()
    }

    public func start() async {
        guard !didStart else { return }
        didStart = true
        startDriverEventLoopIfNeeded()
        await MainActor.run {
            driver.startBrowsing(serviceType: serviceType, domain: domain)
        }
    }

    public func stop() async {
        guard didStart else { return }
        didStart = false
        await MainActor.run {
            driver.stopBrowsing()
        }
        let removed = Array(peers.keys)
        peers.removeAll()
        removed.forEach { broadcast(.removed($0)) }
    }

    public func events() -> AsyncStream<LanDiscoveryEvent> {
        AsyncStream { continuation in
            let token = UUID()
            continuation.onTermination = { [weak self] _ in
                guard let self = self else { return }
                Task { await self.removeContinuation(for: token) }
            }
            self.addContinuation(continuation, for: token)
        }
    }
    
    private func addContinuation(_ continuation: AsyncStream<LanDiscoveryEvent>.Continuation, for token: UUID) {
        continuations[token] = continuation
    }

    public func currentPeers() -> [DiscoveredPeer] {
        Array(peers.values)
    }

    public func prunePeers(olderThan interval: TimeInterval) -> [DiscoveredPeer] {
        let threshold = clock().addingTimeInterval(-interval)
        let staleKeys = peers.filter { $0.value.lastSeen < threshold }.map { $0.key }
        return staleKeys.compactMap { key in
            guard let peer = peers.removeValue(forKey: key) else { return nil }
            broadcast(.removed(peer.serviceName))
            return peer
        }
    }

    private func process(driverEvent: BonjourBrowsingDriverEvent) {
        switch driverEvent {
        case .resolved(let record):
            let metadata = record.txtRecords
            let endpoint = LanEndpoint(
                host: record.host,
                port: record.port,
                deviceId: metadata["device_id"],
                deviceName: metadata["device_name"],
                fingerprint: metadata["fingerprint_sha256"],
                metadata: metadata
            )
            let peer = DiscoveredPeer(
                serviceName: record.serviceName,
                endpoint: endpoint,
                lastSeen: clock()
            )
            peers[record.serviceName] = peer
            broadcast(.added(peer))
        case .removed(let serviceName):
            peers.removeValue(forKey: serviceName)
            broadcast(.removed(serviceName))
        }
    }

    private func broadcast(_ event: LanDiscoveryEvent) {
        continuations.values.forEach { $0.yield(event) }
    }

    private func removeContinuation(for token: UUID) {
        continuations.removeValue(forKey: token)
    }

    private func startDriverEventLoopIfNeeded() {
        guard driverEventTask == nil else { return }
        let stream = driverEventStream
        driverEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                await self.process(driverEvent: event)
            }
        }
    }
}

// MARK: - NetService Implementation

#if canImport(Darwin)
@MainActor
public final class NetServiceBonjourBrowsingDriver: NSObject, BonjourBrowsingDriver, @unchecked Sendable {
    private let browser: NetServiceBrowser
    private var handler: (@Sendable (BonjourBrowsingDriverEvent) -> Void)?
    private var services: [ObjectIdentifier: NetService] = [:]
    private var currentSearch: (serviceType: String, domain: String)?
    private var retryAttempt = 0
    private var isStoppingIntentionally = false
    private let retryPolicy = BrowseRetryPolicy()
    private let logger = HypoLogger(category: "BonjourBrowser")

    public override init() {
        self.browser = NetServiceBrowser()
        super.init()
        browser.delegate = self
    }

    public func setEventHandler(_ handler: @escaping @Sendable (BonjourBrowsingDriverEvent) -> Void) {
        self.handler = handler
    }

    public func startBrowsing(serviceType: String, domain: String) {
        currentSearch = (serviceType, domain)
        retryAttempt = 0
        isStoppingIntentionally = false
        browser.searchForServices(ofType: serviceType, inDomain: domain)
    }

    public func stopBrowsing() {
        isStoppingIntentionally = true
        currentSearch = nil
        browser.stop()
        services.removeAll()
    }

    /// Re-issues a browse that failed or stopped on its own, backing off each time.
    private func scheduleBrowseRetry(reason: String) {
        guard let search = currentSearch, !isStoppingIntentionally else { return }
        retryAttempt += 1
        let delay = retryPolicy.delay(forAttempt: retryAttempt)
        logger.warning("⚠️ [BonjourBrowser] Browse \(reason); retrying in \(Int(delay))s (attempt \(retryAttempt))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let search = self.currentSearch, !self.isStoppingIntentionally else { return }
            self.browser.stop()
            self.browser.searchForServices(ofType: search.serviceType, inDomain: search.domain)
        }
        _ = search
    }

    private func emitResolved(for service: NetService) {
        guard let host = service.hostName else { return }
        
        var ipAddress: String? = nil
        if let addresses = service.addresses, !addresses.isEmpty {
            for addressData in addresses {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = addressData.withUnsafeBytes { bytes -> Int32 in
                    let addr = bytes.baseAddress!.assumingMemoryBound(to: sockaddr.self)
                    return getnameinfo(addr, socklen_t(addressData.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                }
                if result == 0 {
                    ipAddress = hostname.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                    break 
                }
            }
        }
        
        let displayHost = ipAddress ?? host
        let metadata = TXTRecord.parse(service.txtRecordData() ?? Data())
        let record = BonjourServiceRecord(
            serviceName: service.name,
            host: displayHost,
            port: service.port,
            txtRecords: metadata
        )
        handler?(.resolved(record))
    }
}

extension NetServiceBonjourBrowsingDriver: @preconcurrency NetServiceBrowserDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        // A browse that is producing results is healthy; forget the earlier failures.
        retryAttempt = 0
        services[ObjectIdentifier(service)] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeValue(forKey: ObjectIdentifier(service))
        handler?(.removed(service.name))
    }

    public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        services.removeAll()
        // A browse we did not stop ourselves has died; nothing restarts it but us.
        scheduleBrowseRetry(reason: "stopped unexpectedly")
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        services.removeAll()
        let detail = errorDict.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        scheduleBrowseRetry(reason: "failed to start (\(detail))")
    }
}

extension NetServiceBonjourBrowsingDriver: @preconcurrency NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        emitResolved(for: sender)
    }

    public func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        emitResolved(for: sender)
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        services.removeValue(forKey: ObjectIdentifier(sender))
    }
}
#else
@MainActor
public final class NetServiceBonjourBrowsingDriver: BonjourBrowsingDriver, @unchecked Sendable {
    private var handler: (@Sendable (BonjourBrowsingDriverEvent) -> Void)?

    public init() {}

    public func setEventHandler(_ handler: @escaping @Sendable (BonjourBrowsingDriverEvent) -> Void) {
        self.handler = handler
    }

    public func startBrowsing(serviceType: String, domain: String) {}

    public func stopBrowsing() {}
}
#endif
