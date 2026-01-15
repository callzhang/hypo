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

    public override init() {
        self.browser = NetServiceBrowser()
        super.init()
        browser.delegate = self
    }

    public func setEventHandler(_ handler: @escaping @Sendable (BonjourBrowsingDriverEvent) -> Void) {
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
        let txt = NetService.dictionary(fromTXTRecord: service.txtRecordData() ?? Data())
        var metadata: [String: String] = [:]
        for (key, value) in txt {
            metadata[key] = String(data: value, encoding: .utf8) ?? ""
        }
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
