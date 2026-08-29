import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os
#endif
import Network // For NWPathMonitor

/// Event-driven connection status checker that updates device online status in real-time.
/// Uses periodic cloud presence refresh to avoid stale cloud-only statuses.
@MainActor
public final class ConnectionStatusProber {
    private let webSocketServer: LanWebSocketServer
    private weak var transportManager: TransportManager?
    private let transportProvider: TransportProvider?
    private var connectionTask: Task<Void, Never>?
    private var isProbing = false
    private let pathMonitor = NWPathMonitor() // Network monitor
    private let monitorQueue = DispatchQueue(label: "ConnectionStatusProber.NetworkMonitor")
    private var hasNetworkConnectivity = true // Initial assumption
    
    private let logger = HypoLogger(category: "ConnectionStatusProber")
    
    public init(webSocketServer: LanWebSocketServer, transportManager: TransportManager, transportProvider: TransportProvider? = nil) {
        self.webSocketServer = webSocketServer
        self.transportManager = transportManager
        self.transportProvider = transportProvider
        
        // Start network path monitor - listens for network changes and triggers immediate probe
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            Task { @MainActor [self] in
                let newStatus = path.status == .satisfied
                let oldStatus = self.hasNetworkConnectivity
                if oldStatus != newStatus {
                    self.logger.info("🌐", "Network connectivity changed: \(oldStatus) -> \(newStatus) (path status: \(path.status))")
                    self.hasNetworkConnectivity = newStatus
                    // Reconnect cloud WebSocket to use new IP address
                    if newStatus, let transportProvider = self.transportProvider as? DefaultTransportProvider {
                        let cloudTransport = transportProvider.getCloudTransport()
                        self.logger.info("🔄", "Reconnecting cloud WebSocket due to network change")
                        await cloudTransport.reconnect()
                    }
                    // Trigger probe after reconnect attempt to refresh cloud status
                    self.logger.info("🔍", "Triggering probe after network change")
                    await self.probeConnections()
                }
            }
        }
        // Monitor all network interfaces (WiFi, Ethernet, etc.)
        pathMonitor.start(queue: monitorQueue)
    }
    
    deinit {
        // Cancel tasks in deinit (non-isolated context)
        connectionTask?.cancel()
        pathMonitor.cancel() // Stop network monitor
    }
    
    /// Start event-driven connection status checking (no periodic polling)
    public func start() {
        stop() // Stop any existing task
        
        // Set up name lookup for cloud transport
        if let transportProvider = transportProvider as? DefaultTransportProvider {
            let cloudTransport = transportProvider.getCloudTransport()
            cloudTransport.setNameLookup { [weak transportManager] deviceId in
                transportManager?.deviceName(for: deviceId)
            }
        }
        
        // Initial probe on launch (immediate, no delay)
        Task { @MainActor in
            await probeConnections()
        }
        // Periodic cloud status check (mirrors Android 10-minute interval)
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000) // 10 minutes
                if Task.isCancelled { break }
                await self.probeConnections()
            }
        }
    }
    
    /// Stop connection status checking
    public func stop() {
        connectionTask?.cancel()
        connectionTask = nil
    }
    
    /// Probe connections immediately (called on app activation)
    public func probeNow() {
        Task {
            await probeConnections()
        }
    }
    
    /// Probe connection status for all paired devices
    private func probeConnections() async {
        guard !isProbing else {
            return
        }
        
        isProbing = true
        defer { isProbing = false }
        
        // Probing connection status - no logging needed
        
        // Get TransportManager (weakly held)
        guard let transportManager = self.transportManager else {
            logger.info("⚠️ [ConnectionStatusProber] TransportManager is nil, cannot probe")
            return
        }
        
        let pairedDeviceIds = transportManager.pairedDevices.map { $0.id }
        var cloudConnectedDeviceIds = Set<String>()
        var cloudTransportConnected = false
        
        if let transportProvider = transportProvider as? DefaultTransportProvider {
            let cloudTransport = transportProvider.getCloudTransport()
            cloudTransportConnected = cloudTransport.isConnected()
            if cloudTransportConnected {
                do {
                    let connectedPeers = try await withTimeout(seconds: 3.0) {
                        await cloudTransport.queryConnectedPeers(peerIds: pairedDeviceIds)
                    }
                    cloudConnectedDeviceIds = Set(connectedPeers.map { $0.deviceId })
                    let preview = connectedPeers.prefix(5).map { $0.deviceId }.joined(separator: ",")
                    let suffix = connectedPeers.count > 5 ? ", …(+\(connectedPeers.count - 5))" : ""
                    logger.debug("☁️", "Cloud query returned \(connectedPeers.count) devices [\(preview)\(suffix)]")
                } catch {
                    logger.warning("☁️", "Cloud query timeout or error: \(error.localizedDescription)")
                }
            } else {
                logger.debug("☁️", "Cloud transport is NOT connected")
            }
        }
        
        if cloudTransportConnected {
            transportManager.updateConnectionState(.connectedCloud)
        } else if transportManager.hasLanConnections() {
            transportManager.updateConnectionState(.connectedLan)
        } else {
            transportManager.updateConnectionState(.disconnected)
        }
        
        transportManager.updateCloudConnectedDeviceIds(cloudConnectedDeviceIds)
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
