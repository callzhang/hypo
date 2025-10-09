import Foundation

public struct LanEndpoint: Equatable {
    public let host: String
    public let port: Int
    public let fingerprint: String?
    public let metadata: [String: String]

    public init(host: String, port: Int, fingerprint: String?, metadata: [String: String]) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.metadata = metadata
    }
}

public struct DiscoveredPeer: Equatable {
    public let serviceName: String
    public let endpoint: LanEndpoint
    public let lastSeen: Date

    public init(serviceName: String, endpoint: LanEndpoint, lastSeen: Date) {
        self.serviceName = serviceName
        self.endpoint = endpoint
        self.lastSeen = lastSeen
    }
}

public enum LanDiscoveryEvent: Equatable {
    case added(DiscoveredPeer)
    case removed(String)
}

public protocol BonjourBrowsingDriver: AnyObject {
    func startBrowsing(serviceType: String, domain: String)
    func stopBrowsing()
    func setEventHandler(_ handler: @escaping (BonjourBrowsingDriverEvent) -> Void)
}

public enum BonjourBrowsingDriverEvent: Equatable {
    case resolved(BonjourServiceRecord)
    case removed(String)
}

public struct BonjourServiceRecord: Equatable {
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

public actor BonjourBrowser {
    private let serviceType: String
    private let domain: String
    private let driver: BonjourBrowsingDriver
    private let clock: () -> Date
    private let driverEventStream: AsyncStream<BonjourBrowsingDriverEvent>
    private let driverEventContinuation: AsyncStream<BonjourBrowsingDriverEvent>.Continuation

    private var continuations: [UUID: AsyncStream<LanDiscoveryEvent>.Continuation] = [:]
    private var peers: [String: DiscoveredPeer] = [:]
    private var didStart = false
    private var driverEventTask: Task<Void, Never>?

    public init(
        serviceType: String = "_hypo._tcp.",
        domain: String = "local.",
        driver: BonjourBrowsingDriver = NetServiceBonjourBrowsingDriver(),
        clock: @escaping () -> Date = Date.init
    ) {
        var continuation: AsyncStream<BonjourBrowsingDriverEvent>.Continuation!
        self.driverEventStream = AsyncStream { continuation = $0 }
        self.driverEventContinuation = continuation
        self.serviceType = serviceType
        self.domain = domain
        self.driver = driver
        self.clock = clock
        driver.setEventHandler { [weak self] event in
            guard let self else { return }
            self.driverEventContinuation.yield(event)
        }
    }

    deinit {
        driver.stopBrowsing()
        driverEventTask?.cancel()
    }

    public func start() {
        guard !didStart else { return }
        didStart = true
        startDriverEventLoopIfNeeded()
        driver.startBrowsing(serviceType: serviceType, domain: domain)
    }

    public func stop() {
        guard didStart else { return }
        didStart = false
        driver.stopBrowsing()
        let removed = peers.keys
        peers.removeAll()
        removed.forEach { broadcast(.removed($0)) }
    }

    public func events() -> AsyncStream<LanDiscoveryEvent> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(for: token) }
            }
        }
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

#if canImport(Darwin)
public final class NetServiceBonjourBrowsingDriver: NSObject, BonjourBrowsingDriver {
    private let browser: NetServiceBrowser
    private var handler: ((BonjourBrowsingDriverEvent) -> Void)?
    private var services: [ObjectIdentifier: NetService] = [:]

    public override init() {
        self.browser = NetServiceBrowser()
        super.init()
        browser.delegate = self
    }

    public func setEventHandler(_ handler: @escaping (BonjourBrowsingDriverEvent) -> Void) {
        self.handler = handler
    }

    public func startBrowsing(serviceType: String, domain: String) {
        browser.searchForServices(ofType: serviceType, inDomain: domain)
    }

    public func stopBrowsing() {
        browser.stop()
        services.removeAll()
    }

    private func emitResolved(for service: NetService) {
        guard let host = service.hostName else { return }
        let txt = NetService.dictionary(fromTXTRecord: service.txtRecordData() ?? Data())
        var metadata: [String: String] = [:]
        for (key, value) in txt {
            metadata[key] = String(data: value, encoding: .utf8) ?? ""
        }
        let record = BonjourServiceRecord(
            serviceName: service.name,
            host: host,
            port: service.port,
            txtRecords: metadata
        )
        handler?(.resolved(record))
    }
}

extension NetServiceBonjourBrowsingDriver: NetServiceBrowserDelegate {
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
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
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        services.removeAll()
    }
}

extension NetServiceBonjourBrowsingDriver: NetServiceDelegate {
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
public final class NetServiceBonjourBrowsingDriver: BonjourBrowsingDriver {
    private var handler: ((BonjourBrowsingDriverEvent) -> Void)?

    public init() {}

    public func setEventHandler(_ handler: @escaping (BonjourBrowsingDriverEvent) -> Void) {
        self.handler = handler
    }

    public func startBrowsing(serviceType: String, domain: String) {}

    public func stopBrowsing() {}
}
#endif
