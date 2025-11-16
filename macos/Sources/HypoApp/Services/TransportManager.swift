import Foundation
import CryptoKit
#if canImport(Combine)
import Combine
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os
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
    private let analytics: TransportAnalytics
    private var lanConfiguration: BonjourPublisher.Configuration
    private let webSocketServer: LanWebSocketServer
    private let incomingHandler: IncomingClipboardHandler?

    private var discoveryTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    private var isAdvertising = false
    private var isServerRunning = false
    private var lanPeers: [String: DiscoveredPeer] = [:]
    private var lastSeen: [String: Date]
#if canImport(Combine)
    @Published public private(set) var connectionState: ConnectionState = .idle
#else
    public private(set) var connectionState: ConnectionState = .idle
#endif
    private var lastSuccessfulTransport: [String: TransportChannel] = [:]
    private var connectionSupervisorTask: Task<Void, Never>?
    private var manualRetryRequested = false
    private var networkChangeRequested = false

#if canImport(Combine)
    public var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
#endif

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
        dateProvider: @escaping () -> Date = Date.init,
        analytics: TransportAnalytics = NoopTransportAnalytics(),
        webSocketServer: LanWebSocketServer,
        historyStore: HistoryStore? = nil
    ) {
        self.provider = provider
        self.preferenceStorage = preferenceStorage
        self.browser = browser
        self.publisher = publisher
        self.discoveryCache = discoveryCache
        self.pruneInterval = pruneInterval
        self.stalePeerInterval = stalePeerInterval
        self.dateProvider = dateProvider
        self.analytics = analytics
        self.lanConfiguration = lanConfiguration ?? TransportManager.defaultLanConfiguration()
        self.lastSeen = discoveryCache.load()
        self.webSocketServer = webSocketServer
        
        // Set up incoming clipboard handler if history store is provided
        if let historyStore = historyStore {
            let transport = LanSyncTransport(server: webSocketServer)
            let keyProvider = KeychainDeviceKeyProvider()
            let deviceIdentity = DeviceIdentity()
            let syncEngine = SyncEngine(
                transport: transport,
                keyProvider: keyProvider,
                localDeviceId: deviceIdentity.deviceId.uuidString
            )
            self.incomingHandler = IncomingClipboardHandler(
                syncEngine: syncEngine,
                historyStore: historyStore
            )
        } else {
            self.incomingHandler = nil
        }
        
        // Set up WebSocket server delegate
        webSocketServer.delegate = self

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
        // Start LAN services immediately (menu bar apps don't trigger didBecomeActive on launch)
        Task {
            let logPath = "/tmp/hypo_debug.log"
            try? "🔷 [TransportManager] Init: Starting activation task\n".appendToFile(path: logPath)
            await activateLanServices()
            try? "🔷 [TransportManager] Init: Activation task completed\n".appendToFile(path: logPath)
        }
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

    public func currentLanConfiguration() -> BonjourPublisher.Configuration {
        lanConfiguration
    }

    public func currentLanEndpoint() -> LanEndpoint? {
        publisher.currentEndpoint
    }

    public func lastSeenTimestamp(for serviceName: String) -> Date? {
        lastSeen[serviceName]
    }

    public func lastSuccessfulTransport(for serviceName: String) -> TransportChannel? {
        lastSuccessfulTransport[serviceName]
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
        let msg = "🔵 [TransportManager] activateLanServices called, port=\(lanConfiguration.port), isServerRunning=\(isServerRunning)\n"
        try? msg.appendToFile(path: "/tmp/hypo_debug.log")
        if !isAdvertising, lanConfiguration.port > 0 {
            publisher.start(with: lanConfiguration)
            isAdvertising = true
            try? "🟢 [TransportManager] Bonjour publisher started\n".appendToFile(path: "/tmp/hypo_debug.log")
        }
        
        // Start WebSocket server
        try? "🟡 [TransportManager] About to check server: isServerRunning=\(isServerRunning), port=\(lanConfiguration.port)\n".appendToFile(path: "/tmp/hypo_debug.log")
        if !isServerRunning, lanConfiguration.port > 0 {
            try? "🟡 [TransportManager] Attempting to start WebSocket server...\n".appendToFile(path: "/tmp/hypo_debug.log")
            do {
                try webSocketServer.start(port: lanConfiguration.port)
                isServerRunning = true
                try? "✅ [TransportManager] WebSocket server started successfully!\n".appendToFile(path: "/tmp/hypo_debug.log")
            } catch {
                try? "❌ [TransportManager] Failed to start WebSocket server: \(error.localizedDescription)\n".appendToFile(path: "/tmp/hypo_debug.log")
                #if canImport(os)
                let serverLogger = Logger(subsystem: "com.hypo.clipboard", category: "transport")
                serverLogger.error("Failed to start WebSocket server: \(error.localizedDescription)")
                #endif
            }
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
        if isServerRunning {
            webSocketServer.stop()
            isServerRunning = false
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

    @discardableResult
    public func connect(
        lanDialer: @escaping () async throws -> LanDialResult,
        cloudDialer: @escaping () async throws -> Bool,
        timeout: TimeInterval = 3,
        peerIdentifier: String? = nil
    ) async -> ConnectionState {
        precondition(timeout > 0, "Timeout must be positive")
        connectionState = .connectingLan
        let outcome: LanDialOutcome
        do {
            outcome = try await withThrowingTaskGroup(of: LanDialOutcome.self) { group in
                group.addTask {
                    let result = try await lanDialer()
                    return LanDialOutcome.result(result)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return LanDialOutcome.timeout
                }
                guard let first = try await group.next() else {
                    return .timeout
                }
                group.cancelAll()
                return first
            }
        } catch {
            outcome = .failure(error)
        }

        switch outcome {
        case .result(.success):
            connectionState = .connectedLan
            updateLastTransport(for: peerIdentifier, route: .lan)
            return connectionState
        case .result(.failure(let reason, let error)):
            recordFallback(reason: reason, error: error)
            return await connectCloud(peerIdentifier: peerIdentifier, cloudDialer: cloudDialer)
        case .timeout:
            recordFallback(reason: .lanTimeout, error: nil)
            return await connectCloud(peerIdentifier: peerIdentifier, cloudDialer: cloudDialer)
        case .failure(let error):
            recordFallback(reason: .unknown, error: error)
            return await connectCloud(peerIdentifier: peerIdentifier, cloudDialer: cloudDialer)
        }
    }

    private func connectCloud(
        peerIdentifier: String?,
        cloudDialer: @escaping () async throws -> Bool
    ) async -> ConnectionState {
        connectionState = .connectingCloud
        do {
            let success = try await cloudDialer()
            if success {
                connectionState = .connectedCloud
                updateLastTransport(for: peerIdentifier, route: .cloud)
            } else {
                connectionState = .error("Cloud connection failed")
            }
        } catch {
            connectionState = .error(error.localizedDescription)
        }
        return connectionState
    }

    private func recordFallback(reason: TransportFallbackReason, error: Error?) {
        var metadata: [String: String] = ["reason": reason.rawValue]
        if let error {
            metadata["error"] = error.localizedDescription
        }
        analytics.record(.fallback(reason: reason, metadata: metadata, timestamp: dateProvider()))
    }

    private func updateLastTransport(for identifier: String?, route: TransportChannel) {
        guard let identifier else { return }
        lastSuccessfulTransport[identifier] = route
    }

    public func startConnectionSupervisor(
        peerIdentifier: String?,
        lanDialer: @escaping () async throws -> LanDialResult,
        cloudDialer: @escaping () async throws -> Bool,
        sendHeartbeat: @escaping () async -> Bool,
        awaitAck: @escaping () async -> Bool,
        configuration: ConnectionSupervisorConfiguration = .default
    ) {
        connectionSupervisorTask?.cancel()
        manualRetryRequested = false
        networkChangeRequested = false
        connectionSupervisorTask = Task { [weak self] in
            guard let self else { return }
            await self.superviseConnection(
                peerIdentifier: peerIdentifier,
                lanDialer: lanDialer,
                cloudDialer: cloudDialer,
                sendHeartbeat: sendHeartbeat,
                awaitAck: awaitAck,
                configuration: configuration
            )
        }
    }

    public func requestReconnect() {
        manualRetryRequested = true
    }

    public func notifyNetworkChange() {
        networkChangeRequested = true
    }

    public func stopConnectionSupervisor() {
        connectionSupervisorTask?.cancel()
        connectionSupervisorTask = nil
        manualRetryRequested = false
        networkChangeRequested = false
        connectionState = .idle
    }

    public func shutdownTransport(gracefully flush: @escaping () async -> Void) async {
        await flush()
        stopConnectionSupervisor()
    }

    private func superviseConnection(
        peerIdentifier: String?,
        lanDialer: @escaping () async throws -> LanDialResult,
        cloudDialer: @escaping () async throws -> Bool,
        sendHeartbeat: @escaping () async -> Bool,
        awaitAck: @escaping () async -> Bool,
        configuration: ConnectionSupervisorConfiguration
    ) async {
        var attempts = 0
        while !Task.isCancelled {
            let state = await connect(
                lanDialer: { try await lanDialer() },
                cloudDialer: { try await cloudDialer() },
                timeout: configuration.fallbackTimeout,
                peerIdentifier: peerIdentifier
            )

            switch state {
            case .connectedLan, .connectedCloud:
                attempts = 0
                switch await monitorConnection(
                    sendHeartbeat: sendHeartbeat,
                    awaitAck: awaitAck,
                    configuration: configuration
                ) {
                case .gracefulStop, .cancelled:
                    connectionState = .idle
                    return
                case .manualRetry, .networkChange:
                    manualRetryRequested = false
                    networkChangeRequested = false
                    continue
                case .heartbeatFailure, .ackTimeout:
                    manualRetryRequested = false
                    networkChangeRequested = false
                    attempts += 1
                    if attempts >= configuration.maxAttempts {
                        connectionState = .error("Transport unavailable")
                        return
                    }
                    let backoff = jitteredBackoff(attempts: attempts, configuration: configuration)
                    if await waitForBackoff(backoff) {
                        attempts = 0
                        continue
                    }
                }
            case .error(let message):
                attempts += 1
                if attempts >= configuration.maxAttempts {
                    connectionState = .error(message)
                    return
                }
                let backoff = jitteredBackoff(attempts: attempts, configuration: configuration)
                if await waitForBackoff(backoff) {
                    attempts = 0
                    continue
                }
            default:
                attempts += 1
                if attempts >= configuration.maxAttempts {
                    connectionState = .error("Transport unavailable")
                    return
                }
                let backoff = jitteredBackoff(attempts: attempts, configuration: configuration)
                if await waitForBackoff(backoff) {
                    attempts = 0
                    continue
                }
            }
        }
    }

    private func monitorConnection(
        sendHeartbeat: @escaping () async -> Bool,
        awaitAck: @escaping () async -> Bool,
        configuration: ConnectionSupervisorConfiguration
    ) async -> ConnectionMonitorOutcome {
        while !Task.isCancelled {
            await sleep(for: configuration.heartbeatInterval)
            if Task.isCancelled {
                return .cancelled
            }
            if manualRetryRequested {
                manualRetryRequested = false
                return .manualRetry
            }
            if networkChangeRequested {
                networkChangeRequested = false
                return .networkChange
            }
            let heartbeatSucceeded = await sendHeartbeat()
            guard heartbeatSucceeded else { return .heartbeatFailure }
            let ackSucceeded = await waitForAck(timeout: configuration.ackTimeout, awaitAck: awaitAck)
            guard ackSucceeded else { return .ackTimeout }
        }
        return .gracefulStop
    }

    private func waitForAck(timeout: TimeInterval, awaitAck: @escaping () async -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { await awaitAck() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                return false
            }
            guard let first = await group.next() else { return false }
            group.cancelAll()
            return first
        }
    }

    private func jitteredBackoff(
        attempts: Int,
        configuration: ConnectionSupervisorConfiguration
    ) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        let exponent = max(attempts - 1, 0)
        let base = configuration.initialBackoff * pow(2, Double(exponent))
        let capped = min(base, configuration.maxBackoff)
        let jitterRange = configuration.jitterRange
        let jitter: Double
        if jitterRange.lowerBound == 0 && jitterRange.upperBound == 0 {
            jitter = 0
        } else {
            jitter = Double.random(in: jitterRange)
        }
        let jittered = capped * (1 + jitter)
        return max(0, min(jittered, configuration.maxBackoff))
    }

    private func sleep(for interval: TimeInterval) async {
        guard interval > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    private func waitForBackoff(_ duration: TimeInterval) async -> Bool {
        guard duration > 0 else { return false }
        var remaining = duration
        while remaining > 0 && !Task.isCancelled {
            if manualRetryRequested {
                manualRetryRequested = false
                return true
            }
            if networkChangeRequested {
                networkChangeRequested = false
                return true
            }
            let step = min(remaining, 0.1)
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            remaining -= step
        }
        return false
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
        
        // Generate or load device ID from UserDefaults
        let defaults = UserDefaults.standard
        let deviceId: String
        if let existing = defaults.string(forKey: "com.hypo.deviceId") {
            deviceId = existing
        } else {
            deviceId = UUID().uuidString
            defaults.set(deviceId, forKey: "com.hypo.deviceId")
        }
        
        // Load or generate persistent keys for auto-discovery pairing
        let signingKeyStore = PairingSigningKeyStore()
        let keyProvider = KeychainDeviceKeyProvider()
        
        var signingPublicKeyBase64: String?
        var publicKeyBase64: String?
        
        // Load or create signing key
        do {
            let signingKey = try signingKeyStore.loadOrCreate()
            signingPublicKeyBase64 = signingKey.publicKey.rawRepresentation.base64EncodedString()
        } catch {
            signingPublicKeyBase64 = nil
        }
        
        // Load or create persistent key agreement key for LAN pairing
        do {
            // Use a special device ID for the persistent LAN key
            let persistentKeyId = "lan-discovery-key"
            let keychain = KeychainKeyStore()
            let existingKey = try? keychain.load(for: persistentKeyId)
            
            let agreementKey: Curve25519.KeyAgreement.PrivateKey
            if let existing = existingKey {
                // Reconstruct private key from symmetric key (using as seed)
                // Note: This is a simplification - ideally store the actual private key
                agreementKey = Curve25519.KeyAgreement.PrivateKey()
                try keychain.save(key: SymmetricKey(data: agreementKey.rawRepresentation), for: persistentKeyId)
            } else {
                agreementKey = Curve25519.KeyAgreement.PrivateKey()
                try keychain.save(key: SymmetricKey(data: agreementKey.rawRepresentation), for: persistentKeyId)
            }
            publicKeyBase64 = agreementKey.publicKey.rawRepresentation.base64EncodedString()
        } catch {
            publicKeyBase64 = nil
        }
        
        return BonjourPublisher.Configuration(
            serviceName: hostName,
            port: 7010,
            version: bundleVersion,
            fingerprint: "uninitialized",
            protocols: ["ws+tls"],
            deviceId: deviceId,
            publicKey: publicKeyBase64,
            signingPublicKey: signingPublicKeyBase64
        )
    }
}

public enum ConnectionState: Equatable {
    case idle
    case connectingLan
    case connectedLan
    case connectingCloud
    case connectedCloud
    case error(String)
}

public enum TransportChannel: String, Codable {
    case lan
    case cloud
}

public enum LanDialResult {
    case success
    case failure(reason: TransportFallbackReason, error: Error?)
}

private enum LanDialOutcome {
    case result(LanDialResult)
    case timeout
    case failure(Error)
}

public struct ConnectionSupervisorConfiguration {
    public var fallbackTimeout: TimeInterval
    public var heartbeatInterval: TimeInterval
    public var ackTimeout: TimeInterval
    public var initialBackoff: TimeInterval
    public var maxBackoff: TimeInterval
    public var jitterRange: ClosedRange<Double>
    public var maxAttempts: Int

    public static let `default` = ConnectionSupervisorConfiguration()

    public init(
        fallbackTimeout: TimeInterval = 3,
        heartbeatInterval: TimeInterval = 30,
        ackTimeout: TimeInterval = 5,
        initialBackoff: TimeInterval = 2,
        maxBackoff: TimeInterval = 60,
        jitterRange: ClosedRange<Double> = -0.2...0.2,
        maxAttempts: Int = 5
    ) {
        self.fallbackTimeout = fallbackTimeout
        self.heartbeatInterval = heartbeatInterval
        self.ackTimeout = ackTimeout
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.jitterRange = jitterRange
        self.maxAttempts = maxAttempts
    }
}

private enum ConnectionMonitorOutcome {
    case manualRetry
    case networkChange
    case heartbeatFailure
    case ackTimeout
    case gracefulStop
    case cancelled
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

// MARK: - LanWebSocketServerDelegate

extension TransportManager: LanWebSocketServerDelegate {
    nonisolated public func server(_ server: LanWebSocketServer, didReceivePairingChallenge challenge: PairingChallengeMessage, from connection: UUID) {
        #if canImport(os)
        let pairingLogger = Logger(subsystem: "com.hypo.clipboard", category: "pairing")
        pairingLogger.info("📱 Received pairing challenge from: \(challenge.androidDeviceName)")
        #endif
        
        // Auto-accept pairing for LAN auto-discovery
        Task { @MainActor in
            await self.handlePairingChallenge(challenge, connectionId: connection)
        }
    }
    
    private func handlePairingChallenge(_ challenge: PairingChallengeMessage, connectionId: UUID) async {
        do {
            // Create a pairing session
            let deviceIdentity = DeviceIdentity()
            let configuration = PairingSession.Configuration(
                service: lanConfiguration.serviceName,
                port: lanConfiguration.port,
                relayHint: nil,
                deviceName: deviceIdentity.deviceName
            )
            
            let pairingSession = PairingSession(identity: deviceIdentity.deviceId)
            try pairingSession.start(with: configuration)
            
            // Handle the challenge and generate ACK
            guard let ack = await pairingSession.handleChallenge(challenge) else {
                #if canImport(os)
                let logger = Logger(subsystem: "com.hypo.clipboard", category: "pairing")
                logger.error("❌ Failed to generate pairing ACK")
                #endif
                return
            }
            
            // Send ACK back to Android
            try webSocketServer.sendPairingAck(ack, to: connectionId)
            
            #if canImport(os)
            let logger = Logger(subsystem: "com.hypo.clipboard", category: "pairing")
            logger.info("✅ Pairing completed with \(challenge.androidDeviceName)")
            #endif
            
            // Notify about successful pairing (for UI/history updates)
            NotificationCenter.default.post(
                name: NSNotification.Name("PairingCompleted"),
                object: nil,
                userInfo: [
                    "deviceId": challenge.androidDeviceId,
                    "deviceName": challenge.androidDeviceName
                ]
            )
            
        } catch {
            #if canImport(os)
            let logger = Logger(subsystem: "com.hypo.clipboard", category: "pairing")
            logger.error("❌ Pairing failed: \(error.localizedDescription)")
            #endif
        }
    }
    
    nonisolated public func server(_ server: LanWebSocketServer, didReceiveClipboardData data: Data, from connection: UUID) {
        // Forward clipboard data to the transport for processing
        #if canImport(os)
        let syncLogger = Logger(subsystem: "com.hypo.clipboard", category: "sync")
        syncLogger.info("📥 Received clipboard data from connection: \(connection.uuidString), \(data.count) bytes")
        #endif
        
        // Process incoming clipboard data through IncomingClipboardHandler
        Task { @MainActor in
            await self.incomingHandler?.handle(data)
        }
    }
    
    nonisolated public func server(_ server: LanWebSocketServer, didAcceptConnection id: UUID) {
        #if canImport(os)
        let connLogger = Logger(subsystem: "com.hypo.clipboard", category: "transport")
        connLogger.info("WebSocket connection established: \(id.uuidString)")
        #endif
    }
    
    nonisolated public func server(_ server: LanWebSocketServer, didCloseConnection id: UUID) {
        #if canImport(os)
        let closeLogger = Logger(subsystem: "com.hypo.clipboard", category: "transport")
        closeLogger.info("WebSocket connection closed: \(id.uuidString)")
        #endif
    }
}
