import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os
#endif
import Network // For NWPathMonitor

/// Event-driven connection status checker that updates device online status in real-time.
/// Only checks on network changes and app activation - no periodic polling.
@MainActor
public final class ConnectionStatusProber {
    private weak var historyViewModel: ClipboardHistoryViewModel?
    private let webSocketServer: LanWebSocketServer
    private weak var transportManager: TransportManager?
    private let transportProvider: TransportProvider?
    private var connectionTask: Task<Void, Never>?
    private var isProbing = false
    private var isConnecting = false
    private let pathMonitor = NWPathMonitor() // Network monitor
    private let monitorQueue = DispatchQueue(label: "ConnectionStatusProber.NetworkMonitor")
    private var hasNetworkConnectivity = true // Initial assumption
    
    private let logger = HypoLogger(category: "ConnectionStatusProber")
    
    public init(historyViewModel: ClipboardHistoryViewModel, webSocketServer: LanWebSocketServer, transportManager: TransportManager, transportProvider: TransportProvider? = nil) {
        self.historyViewModel = historyViewModel
        self.webSocketServer = webSocketServer
        self.transportManager = transportManager
        self.transportProvider = transportProvider
        
        // Start network path monitor - listens for network changes and triggers immediate probe
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                let newStatus = path.status == .satisfied
                let oldStatus = self?.hasNetworkConnectivity ?? true
                if oldStatus != newStatus {
                    self?.logger.info("🌐", "Network connectivity changed: \(oldStatus) -> \(newStatus) (path status: \(path.status))")
                    self?.hasNetworkConnectivity = newStatus
                    // Reconnect cloud WebSocket to use new IP address
                    if newStatus, let transportProvider = self?.transportProvider as? DefaultTransportProvider {
                        let cloudTransport = transportProvider.getCloudTransport()
                        self?.logger.info("🔄", "Reconnecting cloud WebSocket due to network change")
                        await cloudTransport.reconnect()
                    }
                    // Trigger immediate probe on network change to update server and peer status
                    self?.logger.info("🔍", "Triggering immediate probe due to network change")
                    await self?.probeConnections()
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
        
        logger.info("🔍", "Started - event-driven only (no periodic polling)")
        
        // Initial probe on launch (immediate, no delay)
        Task { @MainActor in
            logger.info("🚀", "Starting initial probe task (immediate)")
            await probeConnections()
            logger.info("✅", "Initial probe task completed")
        }
        
        #if canImport(os)
        logger.info("Connection status prober started (event-driven)")
        #endif
    }
    
    /// Stop connection status checking
    public func stop() {
        connectionTask?.cancel()
        connectionTask = nil
        isConnecting = false
    }
    
    /// Probe connections immediately (called on app activation)
    public func probeNow() {
        Task {
            await probeConnections()
        }
    }
    
    /// Check network connectivity first - fast check
    private func checkNetworkConnectivity() async -> Bool {
        guard let url = URL(string: "https://www.google.com") else {
            return false
        }
        
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 2.0 // 2 seconds - fast check
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200 || httpResponse.statusCode == 301 || httpResponse.statusCode == 302
            }
            return false
        } catch {
            logger.error("🌐", "Network connectivity check failed: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Check server health via HTTP (fallback when WebSocket fails)
    private func checkServerHealth() async -> Bool {
        // First check if we have network connectivity
        let hasNetwork = await checkNetworkConnectivity()
        if !hasNetwork {
            logger.warning("🌐", "No network connectivity - server unreachable")
            return false
        }
        
        guard let url = URL(string: "https://hypo.fly.dev/health") else {
            return false
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3.0 // 3 seconds - faster check
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            logger.error("🏥", "Health check failed: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Probe connection status for all paired devices
    private func probeConnections() async {
        guard !isProbing else {
            logger.debug("⏭️", "Probe already in progress, skipping")
            return
        }
        
        isProbing = true
        defer { isProbing = false }
        
        #if canImport(os)
        logger.info("Probing connection status for paired devices")
        #endif
        logger.debug("probe", "🔍 [ConnectionStatusProber] Probing connection status...\n")
        
        // Get all paired devices from ViewModel
        guard let historyViewModel = historyViewModel else {
            logger.info("⚠️ [ConnectionStatusProber] HistoryViewModel is nil, cannot probe")
            return
        }
        
        let pairedDevices = historyViewModel.pairedDevices
        
        // Get active connections from WebSocket server
        let activeConnectionIds = webSocketServer.activeConnections()
        logger.debug("found", "🔍 [ConnectionStatusProber] Found \(activeConnectionIds.count) active WebSocket connections\n")
        
        // Get device IDs from active connections
        var onlineDeviceIds = Set<String>()
        for connectionId in activeConnectionIds {
            if let metadata = webSocketServer.connectionMetadata(for: connectionId),
               let deviceId = metadata.deviceId {
                onlineDeviceIds.insert(deviceId)
            }
        }
        
        // Get discovered peers via Bonjour
        var discoveredDeviceIds = Set<String>()
        if let transportManager = transportManager {
            let discoveredPeers = transportManager.lanDiscoveredPeers()
            logger.debug("discovery", "🔍 [ConnectionStatusProber] Found \(discoveredPeers.count) discovered peers (all peers: \(discoveredPeers.map { "\($0.serviceName):\($0.endpoint.metadata["device_id"] ?? "none")" }.joined(separator: ", ")))\n")
            for peer in discoveredPeers {
                if let deviceId = peer.endpoint.metadata["device_id"] {
                    discoveredDeviceIds.insert(deviceId)
                    logger.debug("peer", "   ✅ Peer: \(peer.serviceName), device_id=\(deviceId)\n")
                    
                    // Also check if this device ID matches any paired device (case-insensitive)
                    for device in pairedDevices {
                        if device.id.lowercased() == deviceId.lowercased() {
                            logger.debug("match", "   ✅ Matched discovered peer to paired device: \(device.name) (\(device.id) == \(deviceId))\n")
                            // Ensure we're using the paired device's ID (in case of case differences)
                            discoveredDeviceIds.insert(device.id)
                            break
                        }
                    }
                } else {
                    logger.debug("peer", "   ⚠️ Peer: \(peer.serviceName), no device_id attribute\n")
                    // Fallback: match by service name
                    for device in pairedDevices {
                        if peer.serviceName.contains(device.id) || device.id.contains(peer.serviceName) {
                            discoveredDeviceIds.insert(device.id)
                            logger.debug("match", "   ✅ Matched by service name: \(device.id)\n")
                            break
                        }
                    }
                }
            }
            logger.debug("discovered", "🔍 [ConnectionStatusProber] discoveredDeviceIds: \(discoveredDeviceIds)\n")
        }
        
        // Check network connectivity - update status immediately if disconnected
        if !hasNetworkConnectivity {
            transportManager?.updateConnectionState(.disconnected)
        } else {
            // Verify network with HTTP check
            let hasNetwork = await checkNetworkConnectivity()
            if !hasNetwork {
                hasNetworkConnectivity = false
                transportManager?.updateConnectionState(.disconnected)
            } else {
                hasNetworkConnectivity = true
            }
        }
        
        // Update server connection state (only if network is available)
        if hasNetworkConnectivity {
            var cloudTransportConnected = false
            if let transportProvider = transportProvider as? DefaultTransportProvider {
                cloudTransportConnected = transportProvider.getCloudTransport().isConnected()
            }
            
            if cloudTransportConnected {
                transportManager?.updateConnectionState(.connectedCloud)
            } else if !isConnecting {
                // Try to connect to cloud if not already connecting
                isConnecting = true
                transportManager?.updateConnectionState(.connectingCloud)
                
                // Actually connect to cloud relay (not just check health)
                if let transportProvider = transportProvider as? DefaultTransportProvider {
                    let cloudTransport = transportProvider.getCloudTransport()
                    do {
                        try await cloudTransport.connect()
                        transportManager?.updateConnectionState(.connectedCloud)
                        logger.info("connect", "✅ [ConnectionStatusProber] Successfully connected to cloud relay\n")
                    } catch {
                        // Connection failed, check if we have LAN connections
                        let hasLanConnection = !onlineDeviceIds.isEmpty || !discoveredDeviceIds.isEmpty
                        transportManager?.updateConnectionState(hasLanConnection ? .connectedLan : .disconnected)
                        logger.info("error", "❌ [ConnectionStatusProber] Cloud connection failed: \(error.localizedDescription)\n")
                    }
                } else {
                    // No transport provider, check server health as fallback
                    let serverReachable = await checkServerHealth()
                    if serverReachable {
                        transportManager?.updateConnectionState(.connectedCloud)
                    } else {
                        // No cloud, check if we have LAN connections
                        let hasLanConnection = !onlineDeviceIds.isEmpty || !discoveredDeviceIds.isEmpty
                        transportManager?.updateConnectionState(hasLanConnection ? .connectedLan : .disconnected)
                    }
                }
                isConnecting = false
            }
        }
        
        // Get current connection state to determine if server is available
        let currentConnectionState = transportManager?.connectionState ?? .disconnected
        
        // Update status for each paired device - MIRROR ANDROID LOGIC
        logger.debug("checkDevices", "🔍 [ConnectionStatusProber] Checking \(pairedDevices.count) paired devices\n")
        
        for device in pairedDevices {
            // Check for active connection (case-insensitive matching)
            let hasActiveConnection = onlineDeviceIds.contains(device.id) || 
                onlineDeviceIds.contains { $0.lowercased() == device.id.lowercased() }
            
            // Check if discovered (case-insensitive matching)
            let isDiscovered = discoveredDeviceIds.contains(device.id) || 
                discoveredDeviceIds.contains { $0.lowercased() == device.id.lowercased() }
            
            // Update device with discovery information if found
            if isDiscovered, let transportManager = transportManager {
                let discoveredPeers = transportManager.lanDiscoveredPeers()
                // Match by device ID (case-insensitive)
                if let peer = discoveredPeers.first(where: { peer in
                    if let peerDeviceId = peer.endpoint.metadata["device_id"] {
                        return peerDeviceId.lowercased() == device.id.lowercased()
                    }
                    return false
                }) {
                    // Update device with discovery info - ensure we're on MainActor
                    let updatedDevice = device.updating(from: peer)
                    await MainActor.run {
                        historyViewModel.registerPairedDevice(updatedDevice)
                    }
                    logger.debug("update", "   🔄 Updated device \(device.name) with discovery info: \(peer.endpoint.host):\(peer.endpoint.port)\n")
                }
            }
            
            // Get stored transport status for this device (matches Android's lastSuccessfulTransport)
            // Note: TransportManager stores transport by service name/identifier, which may differ from device ID
            // We try multiple lookup strategies to find the stored transport status
            var deviceTransport: TransportChannel? = nil
            if let transportManager = transportManager {
                // Try multiple identifiers: device ID, device name, service name, and service name patterns
                deviceTransport = transportManager.lastSuccessfulTransport(for: device.id)
                    ?? transportManager.lastSuccessfulTransport(for: device.name)
                    ?? (device.serviceName != nil ? transportManager.lastSuccessfulTransport(for: device.serviceName!) : nil)
                    ?? transportManager.lastSuccessfulTransport(for: "\(device.id)-\(device.name)")
                
                // Also check discovered peers for matching service names
                if deviceTransport == nil {
                    let discoveredPeers = transportManager.lanDiscoveredPeers()
                    for peer in discoveredPeers {
                        if let peerDeviceId = peer.endpoint.metadata["device_id"], peerDeviceId == device.id {
                            deviceTransport = transportManager.lastSuccessfulTransport(for: peer.serviceName)
                            break
                        }
                    }
                }
            }
            
            // Determine device online status - REAL-TIME STATUS (no grace period):
            // Devices are only online if they are:
            //   1. Discovered on LAN (active discovery) - LAN discovery means network is available
            //   2. Have an active WebSocket connection (LAN or cloud)
            //   3. Have cloud transport AND server is connected via cloud (device connected via cloud relay)
            let isOnline: Bool
            if isDiscovered || hasActiveConnection {
                // Device is discovered on LAN or has active connection - definitely online
                isOnline = true
            } else if deviceTransport == .cloud && currentConnectionState == .connectedCloud {
                // Device has cloud transport and server is connected - device is reachable via cloud
                isOnline = true
            } else if currentConnectionState == .disconnected {
                // No network connectivity and device not discovered - offline
                isOnline = false
            } else {
                // Network available but device not discovered and no active connection - offline
                isOnline = false
            }
            
            logger.debug("deviceStatus", "🔍 [ConnectionStatusProber] Device \(device.name) (\(device.id.prefix(20))...): hasConnection=\(hasActiveConnection), isDiscovered=\(isDiscovered), transport=\(deviceTransport?.rawValue ?? "none"), connectionState=\(currentConnectionState) → isOnline=\(isOnline)\n")
            
            // Only update if status changed
            if device.isOnline != isOnline {
                logger.info("update", "🔄 [ConnectionStatusProber] Updating device \(device.name) status: \(device.isOnline) → \(isOnline) (connection=\(hasActiveConnection), discovered=\(isDiscovered), transport=\(deviceTransport?.rawValue ?? "none"), connectionState=\(currentConnectionState))\n")
                await historyViewModel.updateDeviceOnlineStatus(deviceId: device.id, isOnline: isOnline)
            } else {
                logger.debug("unchanged", "ℹ️ [ConnectionStatusProber] Device \(device.name) status unchanged: \(isOnline) (connection=\(hasActiveConnection), discovered=\(isDiscovered), transport=\(deviceTransport?.rawValue ?? "none"), connectionState=\(currentConnectionState))\n")
            }
        }
        
        logger.debug("complete", "✅ [ConnectionStatusProber] Probe complete - \(onlineDeviceIds.count) devices with active LAN connections, \(discoveredDeviceIds.count) devices discovered, connectionState: \(currentConnectionState)\n")
    }
}
