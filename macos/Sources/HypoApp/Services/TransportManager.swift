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
#if canImport(Network)
import Network
#endif
#if canImport(Darwin)
import Darwin
#endif

@MainActor
public final class TransportManager: ObservableObject {
    private let logger = HypoLogger(category: "TransportManager")
    private let defaults: UserDefaults
    private let provider: TransportProvider
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
    private weak var historyViewModel: ClipboardHistoryViewModel?
    private var connectionStatusProber: ConnectionStatusProber?
    private var lanConnectedDeviceIds = Set<String>()
    private var cloudConnectedDeviceIds = Set<String>()
    private var connectionDeviceIds: [UUID: String] = [:]
    public let dispatcher: ClipboardEventDispatcher

    private var discoveryTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var networkMonitorTask: Task<Void, Never>?
#if canImport(Network)
    private var hasSeenNetworkPathUpdate = false
    private var lastNetworkPathStatus: NWPath.Status?
    private var lastKnownIP: String?
#endif
    private var isAdvertising = false
    private var isServerRunning = false
    private var lanPeers: [String: DiscoveredPeer] = [:]
    private var lastSeen: [String: Date]
#if canImport(Combine)
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    // Peer state managed by TransportManager
    @Published public private(set) var pairedDevices: [PairedDevice] = []
#else
    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var pairedDevices: [PairedDevice] = []
#endif

    // Cache for synchronous name lookup
    private var deviceNameCache: [String: String] = [:]

    // Messaging and transport state
    private var lastSuccessfulTransportMap: [String: TransportChannel] = [:]
    
    public func pairingParameters() -> (service: String, port: Int, relayHint: URL?) {
        let config = currentLanConfiguration()
        let domain = config.domain
        let serviceType = config.serviceType
        let serviceName = config.serviceName
        let port = config.port
        let service = "\(serviceName).\(serviceType)\(domain)"

        let relayConfig = CloudRelayDefaults.staging()
        var relayComponents = URLComponents(url: relayConfig.url, resolvingAgainstBaseURL: false)
        if relayComponents?.scheme == "wss" { relayComponents?.scheme = "https" }
        let relayHint = relayComponents?.url
        return (service: service, port: port, relayHint: relayHint)
    }
    private var connectionSupervisorTask: Task<Void, Never>?
    private var autoConnectTask: Task<Void, Never>?
    private var initTask: Task<Void, Never>?
    private var manualRetryRequested = false
    private var networkChangeRequested = false
    static let lanPairingKeyIdentifier = "lan-discovery-key"

#if canImport(Combine)
    public var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
#endif

    public var webSocketServerInstance: LanWebSocketServer { webSocketServer }

    #if canImport(AppKit)
    private var lifecycleObserver: ApplicationLifecycleObserver?
    #endif

    private let notificationController: ClipboardNotificationScheduling

    public init(
        provider: TransportProvider,
        browser: BonjourBrowser = BonjourBrowser(),
        publisher: BonjourPublishing = BonjourPublisher(),
        discoveryCache: LanDiscoveryCache = UserDefaultsLanDiscoveryCache(),
        lanConfiguration: BonjourPublisher.Configuration? = nil,
        pruneInterval: TimeInterval = 60,
        stalePeerInterval: TimeInterval = 300,
        dateProvider: @escaping () -> Date = Date.init,
        analytics: TransportAnalytics = NoopTransportAnalytics(),
        webSocketServer: LanWebSocketServer,
        historyStore: HistoryStore? = nil,
        defaults: UserDefaults = .standard,
        dispatcher: ClipboardEventDispatcher? = nil,
        notificationController: ClipboardNotificationScheduling = ClipboardNotificationController.shared
    ) {
        self.defaults = defaults
        self.provider = provider
        self.browser = browser
        self.publisher = publisher
        self.discoveryCache = discoveryCache
        self.pruneInterval = pruneInterval
        self.stalePeerInterval = stalePeerInterval
        self.dateProvider = dateProvider
        self.analytics = analytics
        self.lanConfiguration = lanConfiguration ?? TransportManager.defaultLanConfiguration()
        self.lastSeen = discoveryCache.load()
        // Restore persisted peers from cache
        let cachedPeers = discoveryCache.loadPeers()
        self.lanPeers = cachedPeers
        self.webSocketServer = webSocketServer
        self.dispatcher = dispatcher ?? ClipboardEventDispatcher()
        self.notificationController = notificationController

        // Configure TempFileManager with the dispatcher
        TempFileManager.shared.configure(dispatcher: self.dispatcher)


        // Set up incoming clipboard handler if history store is provided
        if let historyStore = historyStore {
            let transport = LanSyncTransport(server: webSocketServer)
            let keyProvider = KeychainDeviceKeyProvider()
            let deviceIdentity = DeviceIdentity()
            // Set local device ID in WebSocket server for target filtering
            webSocketServer.setLocalDeviceId(deviceIdentity.deviceId.uuidString)
            let syncEngine = SyncEngine(
                transport: transport,
                keyProvider: keyProvider,
                localDeviceId: deviceIdentity.deviceId.uuidString,
                localPlatform: deviceIdentity.platform
            )
            // Create handler - callback will be set up later via setHistoryViewModel
            // Note: In future phases, dispatcher will be passed here
            self.incomingHandler = IncomingClipboardHandler(
                syncEngine: syncEngine,
                historyStore: historyStore,
                dispatcher: self.dispatcher
            )
            
            // Wire handler callbacks for TransportManager internal needs
            self.incomingHandler?.onClipboardReceived = { [weak self] deviceId, timestamp in
                Task { @MainActor in
                    self?.updatePairedDeviceLastSeen(deviceId, lastSeen: timestamp)
                }
            }

            // Allow LanSyncTransport to resolve peers from our discovery cache
            transport.setGetDiscoveredPeers { [weak self] in
                guard let self else { return [] }
                return self.lanDiscoveredPeers()
            }
            // Allow LanSyncTransport to resolve device names for logging
            transport.setTransportManager(self)
        } else {
            self.incomingHandler = nil
        }

        logger.info("🔄 [TransportManager] Restored \(cachedPeers.count) peers from cache")
        logger.info("🆕 [TransportManager] Initialized instance: \(Unmanaged.passUnretained(self).toOpaque()) on thread: \(Thread.current)")
        if Thread.isMainThread {
            logger.info("✅ [TransportManager] init running on Main Thread")
        } else {
            logger.warning("⚠️ [TransportManager] init running on BACKGROUND Thread: \(Thread.current)")
        }

        // Load persisted paired devices (including migration from legacy key)
        loadPairedDevices()

        // Allow outbound LAN client dials (in DefaultTransportProvider) to reuse discovery/cache results
        if let defaultProvider = provider as? DefaultTransportProvider {
            defaultProvider.setGetDiscoveredPeers { [weak self] in
                guard let self else { return [] }
                return self.lanDiscoveredPeers()
            }
        }
        
        // Set up WebSocket server delegate
        webSocketServer.delegate = self
        
        // Set up cloud relay incoming message handler
        if let defaultProvider = provider as? DefaultTransportProvider,
           let handler = incomingHandler {
           defaultProvider.setCloudIncomingMessageHandler { [weak self, weak handler] data, transportOrigin in
               self?.logger.info("📥 [TransportManager] Cloud relay incoming message received: \(data.count.formattedAsKB), origin=\(transportOrigin.rawValue)")
               // Decode envelope to log target device ID
               do {
                   let frameCodec = TransportFrameCodec()
                   let envelope = try frameCodec.decode(data)
                   self?.logger.info("🔍 [TransportManager] Envelope details: type=\(envelope.type.rawValue), target=\(envelope.payload.target ?? "nil"), deviceId=\(envelope.payload.deviceId.prefix(8))")
               } catch {
                   self?.logger.error("❌ [TransportManager] Failed to decode envelope for logging: \(error)")
               }
               
               await handler?.handle(data, transportOrigin: transportOrigin)
           }
        }

        #if canImport(AppKit)
        // Consolidated Application Lifecycle Observer
        self.lifecycleObserver = ApplicationLifecycleObserver(
            onActivate: { [weak self] in
                Task { @MainActor in
                    await self?.activateLanServices()
                }
            },
            onDeactivate: {
                // Don't deactivate LAN services on window close for menu bar apps
                // Services should stay running in the background
            },
            onTerminate: { [weak self] in
                Task { await self?.shutdownLanServices() }
            }
        )
        // Start LAN services immediately (menu bar apps don't trigger didBecomeActive on launch)
        initTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.activateLanServices()
            self.logger.info("➡️ [TransportManager] LAN services activated in initTask")
        }
        #else
        Task { await activateLanServices() }
        #endif
    }
    // MARK: - Peer State Management

    public func updateDeviceOnlineStatus(deviceId: String, isOnline: Bool, skipLog: Bool = false) {
        guard let index = pairedDevices.firstIndex(where: { $0.id == deviceId }) else {
            if !skipLog {
                let instanceAddr = Unmanaged.passUnretained(self).toOpaque()
                logger.warning("⚠️ [TransportManager] Attempted to update status for unknown device: \(deviceId) on instance \(instanceAddr)")
            }
            return
        }
        
        if pairedDevices[index].isOnline != isOnline {
            if !skipLog {
                let instanceAddr = Unmanaged.passUnretained(self).toOpaque()
                logger.info("🔄 [TransportManager] Device status changed: \(pairedDevices[index].name) is now \(isOnline ? "Online" : "Offline") on instance \(instanceAddr)")
            }
            pairedDevices[index].isOnline = isOnline
            
            // Send notification for status change
            let deviceName = pairedDevices[index].name
            let statusText = isOnline ? "Online" : "Offline"
            notificationController.deliverStatusNotification(
                title: "Device Status Changed",
                body: "\(deviceName) is now \(statusText)"
            )
            
            // Explicitly notify change to ensure SwiftUI picks it up across potential actor boundaries
            objectWillChange.send()
        }
    }

    @MainActor
    private func canonicalDeviceId(for deviceId: String) -> String {
        if let device = pairedDevices.first(where: { $0.id.caseInsensitiveCompare(deviceId) == .orderedSame }) {
            return device.id
        }
        return deviceId
    }

    @MainActor
    public func setLanConnection(deviceId: String, isConnected: Bool) {
        let canonicalId = canonicalDeviceId(for: deviceId)
        let normalizedId = canonicalId.lowercased()
        if isConnected {
            lanConnectedDeviceIds.insert(normalizedId)
        } else {
            lanConnectedDeviceIds.remove(normalizedId)
        }
        let isOnline = lanConnectedDeviceIds.contains(normalizedId) || cloudConnectedDeviceIds.contains(normalizedId)
        updateDeviceOnlineStatus(deviceId: canonicalId, isOnline: isOnline)
        // When LAN connects, delay cloud probe to give peer time to complete cloud connection
        // Avoids race where we query before peer finishes cloud handshake (typical 1-3 sec startup delay)
        if isConnected, connectionState != .connectedCloud {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 second delay
                connectionStatusProber?.probeNow()
            }
        }
    }

    @MainActor
    public func updateCloudConnectedDeviceIds(_ deviceIds: Set<String>) {
        cloudConnectedDeviceIds = Set(deviceIds.map { $0.lowercased() })
        
        // Collect status changes for summary logging
        var statusSummary: [String] = []
        
        for device in pairedDevices {
            let normalizedId = device.id.lowercased()
            let isOnline = lanConnectedDeviceIds.contains(normalizedId) || cloudConnectedDeviceIds.contains(normalizedId)
            let wasOnline = device.isOnline
            updateDeviceOnlineStatus(deviceId: device.id, isOnline: isOnline, skipLog: true)
            
            // Track status for summary
            let status = isOnline ? "online" : "offline"
            let changed = wasOnline != isOnline ? " (changed)" : ""
            statusSummary.append("\(device.name): \(status)\(changed)")
        }
        
        // Log single summary line
        let instanceAddr = Unmanaged.passUnretained(self).toOpaque()
        logger.debug("🔍 [TransportManager] Peer status: [\(statusSummary.joined(separator: ", "))] on instance \(instanceAddr)")
    }

    @MainActor
    public func hasLanConnections() -> Bool {
        !lanConnectedDeviceIds.isEmpty
    }

    public func addPairedDevice(_ device: PairedDevice) {
        if !pairedDevices.contains(where: { $0.id == device.id }) {
            pairedDevices.append(device)
            pairedDevices.sort { $0.lastSeen > $1.lastSeen }
            persistPairedDevices()
            logger.info("✅ [TransportManager] Added paired device: \(device.name)")
        }
    }

    public func removePairedDevice(_ device: PairedDevice) {
        if let index = pairedDevices.firstIndex(where: { $0.id == device.id }) {
            pairedDevices.remove(at: index)
            persistPairedDevices()
            logger.info("🗑️ [TransportManager] Removed paired device: \(device.name)")
        }
    }

    public func updatePairedDeviceLastSeen(_ deviceId: String, lastSeen: Date) {
        if let index = pairedDevices.firstIndex(where: { $0.id == deviceId }) {
            var device = pairedDevices[index]
            device.lastSeen = lastSeen
            pairedDevices[index] = device
            pairedDevices.sort { $0.lastSeen > $1.lastSeen }
            persistPairedDevices()
        }
    }

    public func registerPairedDevice(_ device: PairedDevice) {
        // Create a new array to ensure updates
        var updatedDevices = pairedDevices
        
        if let index = updatedDevices.firstIndex(where: { $0.id == device.id }) {
            let existing = updatedDevices[index]
            if existing.id == device.id && existing.isOnline == device.isOnline && existing.serviceName == device.serviceName && existing.bonjourHost == device.bonjourHost && existing.bonjourPort == device.bonjourPort {
                // No meaningful change, skip logging
            } else {
                logger.info("🔄 [TransportManager] Updated existing device: \(device.name)")
            }
            updatedDevices[index] = device
        } else if let existingIndex = updatedDevices.firstIndex(where: { $0.name == device.name && $0.platform == device.platform }) {
            updatedDevices[existingIndex] = device
            logger.info("🔄 [TransportManager] Updated device by name: \(device.name)")
        } else {
            updatedDevices.append(device)
            logger.info("🔄 [TransportManager] Added new device: \(device.name)")
        }
        
        updatedDevices.sort { $0.lastSeen > $1.lastSeen }
        pairedDevices = updatedDevices
        persistPairedDevices()
    }

    // MARK: - Helper Methods

    /// Synchronous name lookup from cache
    public func deviceName(for deviceId: String) -> String? {
        deviceNameCache[deviceId.lowercased()]
    }
    
    /// Get device name for logging, with fallback to truncated UUID
    public func getDeviceName(_ deviceId: String) -> String {
        if let name = deviceName(for: deviceId) {
            return name
        }
        // Fallback to truncated UUID with ellipsis
        return "\(deviceId.prefix(8))..."
    }

    private func updateNameCache() {
        deviceNameCache = Dictionary(
            pairedDevices.map { ($0.id.lowercased(), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func loadPairedDevices() {
        if let data = defaults.data(forKey: "transport_paired_devices"),
           let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            let uniqueDevices = Dictionary(grouping: devices, by: { $0.id })
            .compactMap { $0.value.first }
            .sorted { $0.lastSeen > $1.lastSeen }

            pairedDevices = uniqueDevices
        } else {
            pairedDevices = []
        }

        updateNameCache()
        logger.info("🔄 [TransportManager] Loaded \(pairedDevices.count) paired devices")
    }

    private func persistPairedDevices() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            defaults.set(data, forKey: "transport_paired_devices")
        }
        updateNameCache()
    }
    public func loadTransport() -> SyncTransport {
        return provider.preferredTransport()
    }

    public func setHistoryViewModel(_ viewModel: ClipboardHistoryViewModel) {
        // Prevent duplicate initialization
        guard self.historyViewModel == nil || connectionStatusProber == nil else {
            logger.info("🔧 [TransportManager] setHistoryViewModel already called, skipping")
            return
        }
        
        logger.info("🔧 [TransportManager] setHistoryViewModel called")
        
        self.historyViewModel = viewModel
        // Set up callback for incoming clipboard handler
        incomingHandler?.setOnEntryAdded { [weak self] entry in
            await self?.historyViewModel?.add(entry)
        }
        
        // Initialize connection status prober now that we have the ViewModel
        #if canImport(AppKit)
        if connectionStatusProber == nil {
            logger.info("🔧 [TransportManager] Initializing ConnectionStatusProber")
            
            connectionStatusProber = ConnectionStatusProber(
                webSocketServer: webSocketServer,
                transportManager: self,
                transportProvider: provider
            )
            // Start event-driven checking with periodic cloud status refresh
            connectionStatusProber?.start()
            
            logger.info("🔧 [TransportManager] ConnectionStatusProber started (event-driven + periodic)")
        } else {
            logger.info("🔧 [TransportManager] ConnectionStatusProber already initialized")
        }
        #endif
    }
    
    /// Update the connection state (used by ConnectionStatusProber)
    @MainActor
    public func updateConnectionState(_ newState: ConnectionState) {
        if connectionState != newState {
            let msg = "🔄 [TransportManager] Updating connectionState: \(connectionState) → \(newState)\n"
            logger.info(msg)
            connectionState = newState
        }
    }
    
    /// Start auto-connect to cloud relay
    @MainActor
    private func startAutoConnect() async {
        guard autoConnectTask == nil else {
            logger.debug("⏭️ [TransportManager] Auto-connect already in progress/scheduled")
            return
        }
        
        logger.info("🔄 [TransportManager] Attempting to auto-connect to cloud relay")
        
        autoConnectTask = Task { @MainActor in
            do {
                // Auto-connect to cloud relay after a delay to show server availability
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                
                if let provider = provider as? DefaultTransportProvider {
                    let cloudTransport = provider.getCloudTransport()
                    
                    if cloudTransport.isConnected() {
                        connectionState = .connectedCloud
                        logger.info("✅ [TransportManager] Already connected to cloud relay. Triggering probe.")
                        await probeConnectionStatus()
                        return
                    }
                    
                    connectionState = .connectingCloud
                    do {
                        try await cloudTransport.connect()
                        connectionState = .connectedCloud
                        logger.debug("✅ [TransportManager] Connected to cloud relay, triggering probe")
                        
                        await probeConnectionStatus()
                    } catch {
                        connectionState = .disconnected
                        logger.warning("❌ [TransportManager] Cloud connection failed: \(error.localizedDescription)")
                    }
                }
            } catch {
                logger.error("❌ [TransportManager] Auto-connect task error: \(error.localizedDescription)")
            }
        }
    }

    public func ensureLanDiscoveryActive() async {
        await activateLanServices()
    }
    
    /// Trigger connection status probe to refresh peer status
    public func probeConnectionStatus() async {
        connectionStatusProber?.probeNow()
    }

    public func suspendLanDiscovery() async {
        await deactivateLanServices()
    }

    public func lanDiscoveredPeers() -> [DiscoveredPeer] {
        let allPeers = lanPeers.values.sorted(by: { $0.lastSeen > $1.lastSeen })
        
        // Filter out self
        let deviceIdentity = DeviceIdentity()
        let currentDeviceId = deviceIdentity.deviceId.uuidString.lowercased()
        let currentServiceName = deviceIdentity.deviceName.lowercased()
        
        let filteredPeers = allPeers.filter { peer in
            // Filter by device_id if available
            if let peerDeviceId = peer.endpoint.metadata["device_id"] {
                if peerDeviceId.lowercased() == currentDeviceId {
                    return false
                }
            }
            // Also filter by service name (in case device_id is missing)
            let peerServiceNameLower = peer.serviceName.lowercased()
            if peerServiceNameLower.contains(currentServiceName) || peerServiceNameLower == currentServiceName {
                return false
            }
            return true
        }
        return filteredPeers
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
        lastSuccessfulTransportMap[serviceName]
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
        logger.info("🎬 [TransportManager] activateLanServices called")
        
        if !isAdvertising, lanConfiguration.port > 0 {
            logger.info("📢 [TransportManager] Starting Bonjour advertising on port \(lanConfiguration.port)")
            publisher.start(with: lanConfiguration)
            isAdvertising = true
        } else {
            logger.info("⚠️ [TransportManager] Skipping advertising: isAdvertising=\(isAdvertising), port=\(lanConfiguration.port)")
        }
        
        // Start WebSocket server
        if !isServerRunning, lanConfiguration.port > 0 {
            logger.info("📡 [TransportManager] Starting WebSocket server on port \(lanConfiguration.port)")
            do {
                try webSocketServer.start(port: lanConfiguration.port)
                isServerRunning = true
                logger.info("✅ [TransportManager] WebSocket server started")
            } catch {
                #if canImport(os)
                let serverLogger = HypoLogger(category: "transport")
                serverLogger.error("Failed to start WebSocket server: \(error.localizedDescription)")
                #endif
            }
        } else {
             logger.info("⚠️ [TransportManager] Skipping server start: isServerRunning=\(isServerRunning), port=\(lanConfiguration.port)")
        }

        guard discoveryTask == nil else { 
            logger.info("⚠️ [TransportManager] Discovery task already running, skipping browser start")
            return 
        }

        let stream = await browser.events()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                self.handle(event: event)
            }
        }
        logger.info("🔍 [TransportManager] Starting Bonjour browser")
        await browser.start()
        startPruneTaskIfNeeded()
        startHealthCheckTaskIfNeeded()
        startNetworkMonitorTaskIfNeeded()
        
        // Start cloud auto-connect (guarded against duplicates)
        logger.debug("☁️ [TransportManager] Calling startAutoConnect from activateLanServices")
        await startAutoConnect()
        logger.debug("🎬 [TransportManager] activateLanServices completed")
    }

    public func deactivateLanServices() async {
        discoveryTask?.cancel()
        discoveryTask = nil
        await browser.stop()
        cancelPruneTask()
        cancelHealthCheckTask()
        cancelNetworkMonitorTask()
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
                self.pruneLanPeers(olderThan: self.stalePeerInterval)
            }
        }
    }

    private func cancelPruneTask() {
        pruneTask?.cancel()
        pruneTask = nil
    }

    private func startHealthCheckTaskIfNeeded() {
        guard healthCheckTask == nil else { return }
        healthCheckTask = Task { [weak self] in
            guard let self else { return }
            let interval: UInt64 = 30_000_000_000 // 30 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                
                // Check if advertising should be active but isn't
                if self.lanConfiguration.port > 0 && !self.isAdvertising {
                    self.logger.warning("⚠️ [TransportManager] Health check: Advertising should be active but isn't. Restarting...")
                    await self.activateLanServices()
                }
                
                // Check if WebSocket server should be running but isn't
                if self.lanConfiguration.port > 0 && !self.isServerRunning {
                    self.logger.warning("⚠️ [TransportManager] Health check: WebSocket server should be running but isn't. Restarting...")
                    await self.activateLanServices()
                }
                
                // Verify publisher is still active (check currentEndpoint)
                if self.isAdvertising, self.publisher.currentEndpoint == nil {
                    self.logger.warning("⚠️ [TransportManager] Health check: Publisher endpoint is nil but isAdvertising=true. Restarting...")
                    await self.activateLanServices()
                }
            }
        }
    }

    private func cancelHealthCheckTask() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    private func startNetworkMonitorTaskIfNeeded() {
        guard networkMonitorTask == nil else { return }
        networkMonitorTask = Task { [weak self] in
            guard let self else { return }
            // Monitor network path changes using NWPathMonitor
            #if canImport(Network)
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.hypo.network.monitor")
            
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Skip restart on the very first path update; initial .satisfied
                    // does not represent a real network change and was causing
                    // unnecessary LAN server restarts right after launch.
                    if !self.hasSeenNetworkPathUpdate {
                        self.hasSeenNetworkPathUpdate = true
                        self.lastNetworkPathStatus = path.status
                        // Capture initial IP address
                        self.lastKnownIP = self.getCurrentIPAddress()
                        self.logger.info("🌐 [TransportManager] Initial network path: \(path.status) – IP: \(self.lastKnownIP ?? "unknown")")
                        return
                    }
                    
                    if path.status == .satisfied {
                        // Check if IP address has changed
                        let currentIP = self.getCurrentIPAddress()
                        let ipChanged = currentIP != nil && currentIP != self.lastKnownIP
                        
                        // Only restart when transitioning from a non-satisfied state
                        // to satisfied, OR when IP address changes while path remains satisfied
                        if self.lastNetworkPathStatus != .satisfied {
                            self.logger.info("🌐 [TransportManager] Network path became satisfied. Restarting LAN services to update IP address...")
                            self.lastNetworkPathStatus = .satisfied
                            self.lastKnownIP = currentIP
                            await self.restartLanServicesForNetworkChange()
                        } else if ipChanged {
                            self.logger.info("🌐 [TransportManager] IP address changed: \(self.lastKnownIP ?? "unknown") -> \(currentIP ?? "unknown"). Restarting LAN services...")
                            self.lastKnownIP = currentIP
                            await self.restartLanServicesForNetworkChange()
                        } else {
                            self.logger.info("🌐 [TransportManager] Network path still satisfied – skipping LAN restart")
                        }
                    } else {
                        self.logger.info("🌐 [TransportManager] Network path not satisfied. Status: \(path.status)")
                        self.lastNetworkPathStatus = path.status
                        self.lastKnownIP = nil
                    }
                }
            }
            monitor.start(queue: queue)
            
            // Also periodically check IP address changes (every 10 seconds)
            // This catches IP changes that might not trigger path status changes
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                if Task.isCancelled { break }
                Task { @MainActor [weak self] in
                    guard let self, self.isAdvertising else { return }
                    let currentIP = self.getCurrentIPAddress()
                    if let currentIP = currentIP, currentIP != self.lastKnownIP {
                        self.logger.info("🌐 [TransportManager] Periodic check: IP address changed: \(self.lastKnownIP ?? "unknown") -> \(currentIP). Restarting LAN services...")
                        self.lastKnownIP = currentIP
                        await self.restartLanServicesForNetworkChange()
                    }
                }
            }
            monitor.cancel()
            #else
            // Fallback: periodic check without Network framework
            let interval: UInt64 = 60_000_000_000 // 60 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                // Simple check: if we should be advertising but aren't, restart
                if self.lanConfiguration.port > 0 && !self.isAdvertising {
                    self.logger.info("🌐 [TransportManager] Network monitor: Restarting LAN services...")
                    await self.activateLanServices()
                }
            }
            #endif
        }
    }

    private func cancelNetworkMonitorTask() {
        networkMonitorTask?.cancel()
        networkMonitorTask = nil
    }

    /// Restart LAN services when network changes to update IP address in Bonjour
    private func restartLanServicesForNetworkChange() async {
        let wasAdvertising = isAdvertising
        let wasServerRunning = isServerRunning
        
        // Stop current services and wait for them to fully stop
        if wasAdvertising {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Cast to concrete type to access stop(completion:) method
                if let bonjourPublisher = publisher as? BonjourPublisher {
                    bonjourPublisher.stop {
                        continuation.resume()
                    }
                } else {
                    // Fallback for protocol-only implementation
                    publisher.stop()
                    continuation.resume()
                }
            }
            isAdvertising = false
        }
        if wasServerRunning {
            webSocketServer.stop()
            isServerRunning = false
        }
        
        // Small delay to let network stack settle and ensure old service is fully unregistered
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        
        // Restart services with new network configuration
        if wasAdvertising || wasServerRunning {
            logger.info("🔄 [TransportManager] Restarting LAN services after network change...")
            await activateLanServices()
        }
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
        lastSuccessfulTransportMap[identifier] = route
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
        connectionState = .disconnected
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
                    connectionState = .disconnected
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
            // Filter out self before adding
            let deviceIdentity = DeviceIdentity()
            let currentDeviceId = deviceIdentity.deviceId.uuidString.lowercased()
            let currentServiceName = deviceIdentity.deviceName.lowercased()
            
            // Check if this is self
            var isSelf = false
            if let peerDeviceId = peer.endpoint.metadata["device_id"] {
                if peerDeviceId.lowercased() == currentDeviceId {
                    isSelf = true
                    logger.debug("🔍 [TransportManager] Ignoring self discovery: \(peer.serviceName) (device_id=\(peerDeviceId))")
                }
            }
            if !isSelf {
                let peerServiceNameLower = peer.serviceName.lowercased()
                if peerServiceNameLower.contains(currentServiceName) || peerServiceNameLower == currentServiceName {
                    isSelf = true
                    logger.debug("🔍 [TransportManager] Ignoring self discovery by service name: \(peer.serviceName)")
                }
            }
            
            if isSelf {
                return // Don't add self to discovered peers
            }
            
            if lanPeers[peer.serviceName] == nil {
                logger.info("🔍 [TransportManager] Peer discovered: \(peer.serviceName) at \(peer.endpoint.host):\(peer.endpoint.port), device_id=\(peer.endpoint.metadata["device_id"] ?? "none") (new)")
            } else {
                logger.debug("🔍 [TransportManager] Peer updated: \(peer.serviceName) at \(peer.endpoint.host):\(peer.endpoint.port)")
            }

            lanPeers[peer.serviceName] = peer
            lastSeen[peer.serviceName] = peer.lastSeen
            discoveryCache.save(lastSeen)
            discoveryCache.savePeers(lanPeers) // Persist peer data

            if let peerDeviceId = peer.endpoint.metadata["device_id"] {
                if let device = pairedDevices.first(where: { $0.id.caseInsensitiveCompare(peerDeviceId) == .orderedSame }) {
                    let updatedDevice = device.updating(from: peer)
                    registerPairedDevice(updatedDevice)
                }
            }
            
            // Sync peer connections in LanSyncTransport (maintain persistent connections)
            if let provider = provider as? DefaultTransportProvider {
                Task { @MainActor in
                    await provider.syncPeerConnections()
                }
            }
        case .removed(let serviceName):
            logger.info("🔍 [TransportManager] Peer removed: \(serviceName)")
            lanPeers.removeValue(forKey: serviceName)
            discoveryCache.save(lastSeen)
            discoveryCache.savePeers(lanPeers) // Persist peer data
            
            // Sync peer connections in LanSyncTransport (remove disconnected peer)
            if let provider = provider as? DefaultTransportProvider {
                Task { @MainActor in
                    await provider.syncPeerConnections()
                }
            }
        }
    }
    
    /// Enter sleep mode: Close all connections (LAN & Cloud) for optimization
    /// Connections will be re-established when exitSleepMode() is called.
    public func enterSleepMode() async {
        #if canImport(os)
        logger.info("💤 [TransportManager] Entering sleep mode (closing LAN & Cloud)")
        #endif
        
        if let provider = provider as? DefaultTransportProvider {
            // Close LAN connections
            await provider.getLanTransport().closeAllConnections()
            
            // Close Cloud connection
            let cloudTransport = provider.getCloudTransport()
            await cloudTransport.disconnect()
        }
    }
    
    /// Exit sleep mode: Reconnect all connections (LAN & Cloud)
    /// Re-establishes connections to all discovered peers and relay.
    public func exitSleepMode() async {
        #if canImport(os)
        logger.info("🌅 [TransportManager] Exiting sleep mode (reconnecting LAN & Cloud)")
        #endif
        
        if let provider = provider as? DefaultTransportProvider {
            // Reconnect LAN connections
            await provider.getLanTransport().reconnectAllConnections()
            
            // Reconnect Cloud connection
            let cloudTransport = provider.getCloudTransport()
            try? await cloudTransport.connect()
        }
    }

    private static func defaultLanConfiguration() -> BonjourPublisher.Configuration {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        // Use DeviceIdentity to get consistent device ID format (macos-{UUID})
        let deviceIdentity = DeviceIdentity()
        let deviceId = deviceIdentity.deviceIdString
        
        // Use user-friendly device name for Bonjour service name (e.g. "Derek's MacBook Air")
        // instead of raw hostname (e.g. "dereks-macbook-air-13.local") which causes mDNS issues
        let serviceName = deviceIdentity.deviceName
        
        // Load or generate persistent keys for auto-discovery pairing
        let signingKeyStore = FileBasedPairingSigningKeyStore()
        let _ = KeychainDeviceKeyProvider() // Unused but kept for potential future use
        
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
            let agreementKey = try TransportManager.loadOrCreateLanPairingKey()
            publicKeyBase64 = agreementKey.publicKey.rawRepresentation.base64EncodedString()
            if let preview = publicKeyBase64?.prefix(16) {
                NSLog("🔑 [TransportManager] Bonjour config: Using public key \(preview)...")
            }
        } catch {
            NSLog("❌ [TransportManager] Failed to load/create LAN pairing key for Bonjour: \(error)")
            publicKeyBase64 = nil
        }
        
        // Derive a stable fingerprint from the LAN key agreement public key so peers can pin us.
        let fingerprint: String
        if let publicKeyBase64 = publicKeyBase64, let pubData = Data(base64Encoded: publicKeyBase64) {
            fingerprint = sha256Hex(pubData)
        } else {
            fingerprint = "uninitialized"
        }
        return BonjourPublisher.Configuration(
            serviceName: serviceName,
            port: 7010,
            version: bundleVersion,
            fingerprint: fingerprint,
            protocols: ["ws+tls"],
            deviceId: deviceId,
            publicKey: publicKeyBase64,
            signingPublicKey: signingPublicKeyBase64
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    static func loadOrCreateLanPairingKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        let logger = HypoLogger(category: "TransportManager")
        let keyStore = FileBasedKeyStore()
        if let stored = try keyStore.load(for: TransportManager.lanPairingKeyIdentifier) {
            let data = Data([UInt8](stored.withUnsafeBytes { $0 }))
            logger.info("🔑 [TransportManager] Loading existing LAN pairing key from file storage (size: \(data.count.formattedAsKB))")
            do {
                let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
                logger.info("🔑 [TransportManager] Successfully loaded existing key, public key: \(key.publicKey.rawRepresentation.base64EncodedString().prefix(16))...")
                return key
            } catch {
                logger.error("❌ [TransportManager] Failed to reconstruct key from file storage data: \(error)")
                // If key reconstruction fails, delete the corrupted entry and create a new one
                try? keyStore.delete(for: TransportManager.lanPairingKeyIdentifier)
                throw error
            }
        }

        logger.info("🔑 [TransportManager] Creating new LAN pairing key")
        let key = Curve25519.KeyAgreement.PrivateKey()
        try keyStore.save(key: SymmetricKey(data: key.rawRepresentation), for: TransportManager.lanPairingKeyIdentifier)
        logger.info("🔑 [TransportManager] Saved new key to file storage, public key: \(key.publicKey.rawRepresentation.base64EncodedString().prefix(16))...")
        return key
    }
}

public enum ConnectionState: Equatable {
    case disconnected
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

@MainActor
public protocol TransportProvider {
    func preferredTransport() -> SyncTransport
}

public protocol LanDiscoveryCache {
    func load() -> [String: Date]
    func save(_ lastSeen: [String: Date])
    func loadPeers() -> [String: DiscoveredPeer]
    func savePeers(_ peers: [String: DiscoveredPeer])
}

public struct UserDefaultsLanDiscoveryCache: LanDiscoveryCache {
    private let key = "lan_discovery_last_seen"
    private let peersKey = "lan_discovery_peers"
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
    
    public func loadPeers() -> [String: DiscoveredPeer] {
        guard let data = defaults.data(forKey: peersKey),
              let decoded = try? JSONDecoder().decode([String: CachedPeer].self, from: data) else {
            return [:]
        }
        return decoded.compactMapValues { cachedPeer -> DiscoveredPeer? in
            let endpoint = LanEndpoint(
                host: cachedPeer.host,
                port: cachedPeer.port,
                fingerprint: cachedPeer.fingerprint,
                metadata: cachedPeer.metadata
            )
            return DiscoveredPeer(
                serviceName: cachedPeer.serviceName,
                endpoint: endpoint,
                lastSeen: cachedPeer.lastSeen
            )
        }
    }
    
    public func savePeers(_ peers: [String: DiscoveredPeer]) {
        let cachedPeers = peers.mapValues { peer in
            CachedPeer(
                serviceName: peer.serviceName,
                host: peer.endpoint.host,
                port: peer.endpoint.port,
                fingerprint: peer.endpoint.fingerprint,
                metadata: peer.endpoint.metadata,
                lastSeen: peer.lastSeen
            )
        }
        if let encoded = try? JSONEncoder().encode(cachedPeers) {
            defaults.set(encoded, forKey: peersKey)
        }
    }
    
    private struct CachedPeer: Codable {
        let serviceName: String
        let host: String
        let port: Int
        let fingerprint: String?
        let metadata: [String: String]
        let lastSeen: Date
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
        Task { @MainActor in
            await self.handlePairingChallenge(challenge, connectionId: connection)
        }
    }
    
    private func handlePairingChallenge(_ challenge: PairingChallengeMessage, connectionId: UUID) async {
        logger.info("🔵 [TransportManager] handlePairingChallenge START: device=\(challenge.initiatorDeviceName), connection=\(connectionId.uuidString.prefix(8))")
        // Remove try-catch to let errors propagate
        #if canImport(os)
        let logger = HypoLogger(category: "pairing")
        logger.info("🔄 Processing pairing challenge from: \(challenge.initiatorDeviceName)")
        #endif
        
        do {
            logger.info("🔵 [TransportManager] Inside do block, creating pairing session...")
            // Create a pairing session
            logger.info("🔵 [TransportManager] Creating DeviceIdentity...")
            let deviceIdentity = DeviceIdentity()
            logger.info("🔵 [TransportManager] Creating PairingSession.Configuration...")
            let configuration = PairingSession.Configuration(
                service: lanConfiguration.serviceName,
                port: lanConfiguration.port,
                relayHint: nil,
                deviceName: deviceIdentity.deviceName
            )
            
            #if canImport(os)
            logger.info("📝 Starting pairing session...")
            #endif
            logger.info("🔑 [TransportManager] Loading LAN pairing key for challenge handling...")
            let persistentKey = try TransportManager.loadOrCreateLanPairingKey()
            logger.info("🔑 [TransportManager] Loaded key, public key: \(persistentKey.publicKey.rawRepresentation.base64EncodedString().prefix(16))...")
            logger.info("🔵 [TransportManager] Creating PairingSession...")
            let pairingSession = PairingSession(identity: deviceIdentity.deviceId)
            logger.info("🔵 [TransportManager] Calling pairingSession.start()...")
            try pairingSession.start(with: configuration, keyAgreementKey: persistentKey)
            logger.info("🔑 [TransportManager] Pairing session started with persistent key")
            
            #if canImport(os)
            logger.info("🔐 Handling challenge to generate ACK...")
            #endif
            logger.info("🔵 [TransportManager] About to call pairingSession.handleChallenge()...")
            // Handle the challenge and generate ACK - let errors propagate
            let ackResult = await pairingSession.handleChallenge(challenge)
            logger.info("🔵 [TransportManager] handleChallenge returned, result is \(ackResult == nil ? "nil" : "non-nil")")
            guard let ack = ackResult else {
                #if canImport(os)
                logger.error("❌ Failed to generate pairing ACK - handleChallenge returned nil")
                #endif
                logger.info("❌ [TransportManager] Failed to generate pairing ACK - handleChallenge returned nil")
                return
            }
            
            logger.info("✅ [TransportManager] Guard passed, ACK is non-nil")
            #if canImport(os)
            logger.info("✅ Generated ACK with challengeId: \(ack.challengeId.uuidString)")
            #endif
            logger.info("✅ [TransportManager] Generated ACK with challengeId: \(ack.challengeId.uuidString)")
            
            #if canImport(os)
            // Send ACK back to Android - let errors propagate
            try webSocketServer.sendPairingAck(ack, to: connectionId)
            
            // Update connection metadata with device ID
            webSocketServer.updateConnectionMetadata(connectionId: connectionId, deviceId: challenge.initiatorDeviceId)
            
            logger.info("✅ [TransportManager] Pairing completed: \(challenge.initiatorDeviceName) (\(challenge.initiatorDeviceId.prefix(8)))")

            // Register paired device directly (no notification dependency)
            let discoveredPeer = lanDiscoveredPeers().first(where: { peer in
                if let peerDeviceId = peer.endpoint.metadata["device_id"] {
                    return peerDeviceId.lowercased() == challenge.initiatorDeviceId.lowercased()
                }
                return false
            })
            let pairedDevice: PairedDevice
            if let peer = discoveredPeer {
                pairedDevice = PairedDevice(
                    id: challenge.initiatorDeviceId,
                    name: challenge.initiatorDeviceName,
                    platform: "Android",
                    lastSeen: Date(),
                    isOnline: true,
                    serviceName: peer.serviceName,
                    bonjourHost: peer.endpoint.host,
                    bonjourPort: peer.endpoint.port,
                    fingerprint: peer.endpoint.fingerprint
                )
                logger.info("✅ [TransportManager] Paired device discovered on LAN: \(peer.endpoint.host):\(peer.endpoint.port)")
            } else {
                pairedDevice = PairedDevice(
                    id: challenge.initiatorDeviceId,
                    name: challenge.initiatorDeviceName,
                    platform: "Android",
                    lastSeen: Date(),
                    isOnline: true
                )
                logger.info("✅ [TransportManager] Paired device not yet discovered on LAN (will update when discovered)")
            }
            registerPairedDevice(pairedDevice)
            #endif
        } catch {
            #if canImport(os)
            let logger = HypoLogger(category: "pairing")
            logger.error("❌ Pairing failed with error: \(error.localizedDescription)")
            logger.error("❌ Error type: \(String(describing: type(of: error)))")
            logger.error("❌ Error details: \(error)")
            #endif
            // Log error but don't crash - just return
            logger.error("❌ [TransportManager] Pairing failed: \(error.localizedDescription), type: \(String(describing: type(of: error)))")
            return
        }
    }
    
    nonisolated public func server(_ server: LanWebSocketServer, didReceiveClipboardData data: Data, from connection: UUID) {
        // Forward clipboard data to the transport for processing
        fflush(stdout)  // Force flush stdout
        
        Task { @MainActor in
            // Try to extract deviceId from the frame-encoded data
            let frameCodec = TransportFrameCodec()
            do {
                let envelope = try frameCodec.decode(data)
                let deviceId = envelope.payload.deviceId
                
                // Update connection metadata and mark LAN connection online
                if server.connectionMetadata(for: connection)?.deviceId == nil {
                    server.updateConnectionMetadata(connectionId: connection, deviceId: deviceId)
                }
                connectionDeviceIds[connection] = deviceId
                setLanConnection(deviceId: deviceId, isConnected: true)
            } catch {
                logger.info("⚠️ [TransportManager] Failed to decode envelope for metadata update: \(error)")
                // Try to get deviceId from connection metadata as fallback
                if let metadata = server.connectionMetadata(for: connection),
                   let deviceId = metadata.deviceId {
                    logger.info("✅ [TransportManager] Using deviceId from connection metadata: \(deviceId)")
                    connectionDeviceIds[connection] = deviceId
                    setLanConnection(deviceId: deviceId, isConnected: true)
                }
            }
            
            // Process incoming clipboard data through IncomingClipboardHandler
            logger.info("🔍 [TransportManager] About to call incomingHandler?.handle(data)")
            if let handler = self.incomingHandler {
                logger.info("✅ [TransportManager] incomingHandler exists, calling handle()")
                await handler.handle(data, transportOrigin: .lan)
                logger.info("✅ [TransportManager] incomingHandler.handle() completed")
            } else {
                logger.info("❌ [TransportManager] incomingHandler is nil!")
            }
        }
    }
    
    nonisolated public func server(_ server: LanWebSocketServer, didAcceptConnection id: UUID) {
        #if canImport(os)
        let connLogger = HypoLogger(category: "transport")
        connLogger.info("WebSocket connection established: \(id.uuidString)")
        #endif
        // Update device online status when connection is established
        Task { @MainActor in
            // Try to find device ID from connection metadata
            if let metadata = server.connectionMetadata(for: id),
               let deviceId = metadata.deviceId {
                let metadataMsg = "✅ [TransportManager] Connection established for device: \(deviceId)"
                logger.info(metadataMsg)
                connectionDeviceIds[id] = deviceId
                setLanConnection(deviceId: deviceId, isConnected: true)
                NotificationCenter.default.post(
                    name: NSNotification.Name("DeviceConnectionStatusChanged"),
                    object: nil,
                    userInfo: [
                        "deviceId": deviceId,
                        "isOnline": true
                    ]
                )
            } else {
                logger.info("⚠️ [TransportManager] Connection established but no deviceId in metadata yet (will update when handshake completes)")
            }
        }
    }

    nonisolated public func server(_ server: LanWebSocketServer, didIdentifyConnection id: UUID, deviceId: String) {
        Task { @MainActor in
            connectionDeviceIds[id] = deviceId
            setLanConnection(deviceId: deviceId, isConnected: true)
        }
    }
    
    nonisolated public func server(_ server: LanWebSocketServer, didCloseConnection id: UUID) {
        #if canImport(os)
        let closeLogger = HypoLogger(category: "transport")
        closeLogger.info("WebSocket connection closed: \(id.uuidString)")
        #endif
        // Update device online status when connection is closed
        Task { @MainActor in
            // Try to find device ID from connection metadata before it's removed
            if let metadata = server.connectionMetadata(for: id),
               let deviceId = metadata.deviceId {
                setLanConnection(deviceId: deviceId, isConnected: false)
                NotificationCenter.default.post(
                    name: NSNotification.Name("DeviceConnectionStatusChanged"),
                    object: nil,
                    userInfo: [
                        "deviceId": deviceId,
                        "isOnline": false
                    ]
                )
            } else if let deviceId = connectionDeviceIds[id] {
                setLanConnection(deviceId: deviceId, isConnected: false)
                NotificationCenter.default.post(
                    name: NSNotification.Name("DeviceConnectionStatusChanged"),
                    object: nil,
                    userInfo: [
                        "deviceId": deviceId,
                        "isOnline": false
                    ]
                )
            }
            connectionDeviceIds.removeValue(forKey: id)
        }
    }
}

// MARK: - IP Address Helper

extension TransportManager {
    /// Get the current primary IP address for the active network interface
    private func getCurrentIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee else { continue }
            let flags = Int32(interface.ifa_flags)
            
            // Check if interface is up and not loopback
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) && (flags & IFF_LOOPBACK) == 0 {
                if let addr = interface.ifa_addr {
                    let addrFamily = addr.pointee.sa_family
                    if addrFamily == AF_INET {
                        let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        if let addrString = inet_ntoa(sin.sin_addr) {
                            let ip = String(cString: addrString)
                            // Prefer non-link-local addresses (not 169.254.x.x)
                            if !ip.hasPrefix("169.254.") {
                                address = ip
                                break
                            } else if address == nil {
                                // Fallback to link-local if no other address found
                                address = ip
                            }
                        }
                    }
                }
            }
        }
        
        return address
    }
}
