import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public final class TransportManager {
    private let provider: TransportProvider
    private let preferenceStorage: PreferenceStorage
    private let browser: BonjourBrowser
    private let publisher: BonjourPublishing
    private let discoveryCache: LanDiscoveryCache
    private let pruneInterval: TimeInterval
    private let stalePeerInterval: TimeInterval
    private let dateProvider: () -> Date
    private var lanConfiguration: BonjourPublisher.Configuration

    private var discoveryTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    private var isAdvertising = false
    private var lanPeers: [String: DiscoveredPeer] = [:]
    private var lastSeen: [String: Date]

    #if canImport(AppKit)
    private var lifecycleObserver: ApplicationLifecycleObserver?
    #endif

    public init(
        provider: TransportProvider,
        preferenceStorage: PreferenceStorage = UserDefaultsPreferenceStorage(),
        browser: BonjourBrowser = BonjourBrowser(),
        publisher: BonjourPublishing = BonjourPublisher(),
        discoveryCache: LanDiscoveryCache = UserDefaultsLanDiscoveryCache(),
        lanConfiguration: BonjourPublisher.Configuration? = nil,
        pruneInterval: TimeInterval = 60,
        stalePeerInterval: TimeInterval = 300,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.preferenceStorage = preferenceStorage
        self.browser = browser
        self.publisher = publisher
        self.discoveryCache = discoveryCache
        self.pruneInterval = pruneInterval
        self.stalePeerInterval = stalePeerInterval
        self.dateProvider = dateProvider
        self.lanConfiguration = lanConfiguration ?? TransportManager.defaultLanConfiguration()
        self.lastSeen = discoveryCache.load()

        #if canImport(AppKit)
        lifecycleObserver = ApplicationLifecycleObserver(
            onActivate: { [weak self] in
                Task { await self?.activateLanServices() }
            },
            onDeactivate: { [weak self] in
                Task { await self?.deactivateLanServices() }
            },
            onTerminate: { [weak self] in
                Task { await self?.shutdownLanServices() }
            }
        )
        #else
        Task { await activateLanServices() }
        #endif
    }

    public func loadTransport() -> SyncTransport {
        let preference = currentPreference()
        return provider.preferredTransport(for: preference)
    }

    public func update(preference: TransportPreference) {
        preferenceStorage.savePreference(preference)
    }

    public func currentPreference() -> TransportPreference {
        preferenceStorage.loadPreference() ?? .lanFirst
    }

    public func ensureLanDiscoveryActive() async {
        await activateLanServices()
    }

    public func suspendLanDiscovery() async {
        await deactivateLanServices()
    }

    public func lanDiscoveredPeers() -> [DiscoveredPeer] {
        lanPeers.values.sorted(by: { $0.lastSeen > $1.lastSeen })
    }

    public func lastSeenTimestamp(for serviceName: String) -> Date? {
        lastSeen[serviceName]
    }

    public func pruneLanPeers(olderThan interval: TimeInterval) {
        guard interval > 0 else { return }
        let threshold = dateProvider().addingTimeInterval(-interval)
        lanPeers = lanPeers.filter { $0.value.lastSeen >= threshold }
        lastSeen = lastSeen.filter { $0.value >= threshold }
        discoveryCache.save(lastSeen)
    }

    public func updateLocalAdvertisement(
        port: Int? = nil,
        fingerprint: String? = nil,
        protocols: [String]? = nil,
        version: String? = nil
    ) {
        var updated = lanConfiguration
        if let port {
            updated = BonjourPublisher.Configuration(
                domain: updated.domain,
                serviceType: updated.serviceType,
                serviceName: updated.serviceName,
                port: port,
                version: version ?? updated.version,
                fingerprint: fingerprint ?? updated.fingerprint,
                protocols: protocols ?? updated.protocols
            )
        } else {
            updated = BonjourPublisher.Configuration(
                domain: updated.domain,
                serviceType: updated.serviceType,
                serviceName: updated.serviceName,
                port: updated.port,
                version: version ?? updated.version,
                fingerprint: fingerprint ?? updated.fingerprint,
                protocols: protocols ?? updated.protocols
            )
        }

        let portChanged = updated.port != lanConfiguration.port
        lanConfiguration = updated

        guard isAdvertising else { return }
        if portChanged {
            publisher.stop()
            publisher.start(with: updated)
        } else {
            publisher.updateTXTRecord(updated.txtRecord)
        }
    }

    public func diagnosticsReport() -> String {
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        lines.append("Hypo LAN Diagnostics")
        lines.append("Timestamp: \(formatter.string(from: dateProvider()))")

        if let endpoint = publisher.currentEndpoint {
            lines.append("Local Service: \(lanConfiguration.serviceName) @ \(endpoint.host):\(endpoint.port)")
            if let fingerprint = endpoint.fingerprint {
                lines.append("Fingerprint: \(fingerprint)")
            }
            if !lanConfiguration.protocols.isEmpty {
                lines.append("Protocols: \(lanConfiguration.protocols.joined(separator: ","))")
            }
        } else {
            lines.append("Local Service: inactive")
        }

        if lanPeers.isEmpty {
            lines.append("Discovered Peers: none")
        } else {
            lines.append("Discovered Peers (\(lanPeers.count)):")
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            for peer in lanDiscoveredPeers() {
                lines.append("- \(peer.serviceName) @ \(peer.endpoint.host):\(peer.endpoint.port) (last seen \(formatter.string(from: peer.lastSeen)))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func handleDeepLink(_ url: URL) -> String? {
        guard url.scheme == "hypo", url.host == "debug" else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path == "lan" else { return nil }
        return diagnosticsReport()
    }

    private func activateLanServices() async {
        if !isAdvertising, lanConfiguration.port > 0 {
            publisher.start(with: lanConfiguration)
            isAdvertising = true
        }

        guard discoveryTask == nil else { return }
        let stream = await browser.events()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                self.handle(event: event)
            }
        }
        await browser.start()
        startPruneTaskIfNeeded()
    }

    private func deactivateLanServices() async {
        discoveryTask?.cancel()
        discoveryTask = nil
        await browser.stop()
        cancelPruneTask()
        if isAdvertising {
            publisher.stop()
            isAdvertising = false
        }
    }

    private func shutdownLanServices() async {
        await deactivateLanServices()
    }

    private func startPruneTaskIfNeeded() {
        guard pruneTask == nil, pruneInterval > 0, stalePeerInterval > 0 else { return }
        pruneTask = Task { [weak self] in
            guard let self else { return }
            let interval = UInt64(pruneInterval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self.pruneLanPeers(olderThan: self.stalePeerInterval)
            }
        }
    }

    private func cancelPruneTask() {
        pruneTask?.cancel()
        pruneTask = nil
    }

    private func handle(event: LanDiscoveryEvent) {
        switch event {
        case .added(let peer):
            lanPeers[peer.serviceName] = peer
            lastSeen[peer.serviceName] = peer.lastSeen
            discoveryCache.save(lastSeen)
        case .removed(let serviceName):
            lanPeers.removeValue(forKey: serviceName)
            discoveryCache.save(lastSeen)
        }
    }

    private static func defaultLanConfiguration() -> BonjourPublisher.Configuration {
        let hostName = ProcessInfo.processInfo.hostName
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return BonjourPublisher.Configuration(
            serviceName: hostName,
            port: 7010,
            version: bundleVersion,
            fingerprint: "uninitialized",
            protocols: ["ws+tls"]
        )
    }
}

public enum TransportPreference: String, Codable {
    case lanFirst
    case cloudOnly
}

public protocol TransportProvider {
    func preferredTransport(for preference: TransportPreference) -> SyncTransport
}

public protocol PreferenceStorage {
    func loadPreference() -> TransportPreference?
    func savePreference(_ preference: TransportPreference)
}

public struct UserDefaultsPreferenceStorage: PreferenceStorage {
    private let key = "transport_preference"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadPreference() -> TransportPreference? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return TransportPreference(rawValue: raw)
    }

    public func savePreference(_ preference: TransportPreference) {
        defaults.set(preference.rawValue, forKey: key)
    }
}

public protocol LanDiscoveryCache {
    func load() -> [String: Date]
    func save(_ lastSeen: [String: Date])
}

public struct UserDefaultsLanDiscoveryCache: LanDiscoveryCache {
    private let key = "lan_discovery_last_seen"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [String: Date] {
        guard let stored = defaults.dictionary(forKey: key) as? [String: Double] else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            result[entry.key] = Date(timeIntervalSince1970: entry.value)
        }
    }

    public func save(_ lastSeen: [String: Date]) {
        let payload = lastSeen.reduce(into: [String: Double]()) { result, entry in
            result[entry.key] = entry.value.timeIntervalSince1970
        }
        defaults.set(payload, forKey: key)
    }
}

#if canImport(AppKit)
private final class ApplicationLifecycleObserver {
    private var tokens: [NSObjectProtocol] = []

    init(onActivate: @escaping () -> Void, onDeactivate: @escaping () -> Void, onTerminate: @escaping () -> Void) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            onActivate()
        })
        tokens.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            onDeactivate()
        })
        tokens.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            onTerminate()
        })
    }

    deinit {
        let center = NotificationCenter.default
        tokens.forEach { center.removeObserver($0) }
    }
}
#endif
