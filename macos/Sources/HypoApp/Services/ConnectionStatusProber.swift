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
                    // Trigger immediate probe on network change to update server and peer status
                    self.logger.info("🔍", "Triggering immediate probe due to network change")
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
        
        // Probing connection status - no logging needed
        
        // Get TransportManager (weakly held)
        guard let transportManager = self.transportManager else {
            logger.info("⚠️ [ConnectionStatusProber] TransportManager is nil, cannot probe")
            return
        }
        
        let pairedDevices = transportManager.pairedDevices
        
        // Get active connections from WebSocket server
        let activeConnectionIds = webSocketServer.activeConnections()
        
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
        let discoveredPeers = transportManager.lanDiscoveredPeers()
        
        // Get current device ID to filter out self
        let deviceIdentity = DeviceIdentity()
        let currentDeviceId = deviceIdentity.deviceId.uuidString.lowercased()
        
        for peer in discoveredPeers {
            if let deviceId = peer.endpoint.metadata["device_id"] {
                let peerDeviceIdLower = deviceId.lowercased()
                
                // Filter out self
                if peerDeviceIdLower == currentDeviceId {
                    continue
                }
                
                discoveredDeviceIds.insert(deviceId)
                
                // Also check if this device ID matches any paired device (case-insensitive)
                for device in pairedDevices {
                    if device.id.lowercased() == peerDeviceIdLower {
                        // Ensure we're using the paired device's ID (in case of case differences)
                        discoveredDeviceIds.insert(device.id)
                        break
                    }
                }
            } else {
                // Fallback: match by service name (but still filter out self by service name)
                let serviceNameLower = peer.serviceName.lowercased()
                let currentServiceName = deviceIdentity.deviceName.lowercased()
                if serviceNameLower.contains(currentServiceName) || serviceNameLower == currentServiceName {
                    continue
                }
                
                for device in pairedDevices {
                    if peer.serviceName.contains(device.id) || device.id.contains(peer.serviceName) {
                        discoveredDeviceIds.insert(device.id)
                        break
                    }
                }
            }
        }
        
            // Query cloud relay for connected peers (if cloud is connected) - MIRROR ANDROID LOGIC
            var cloudConnectedDeviceIds = Set<String>()
            if let transportProvider = transportProvider as? DefaultTransportProvider {
                let cloudTransport = transportProvider.getCloudTransport()
                if cloudTransport.isConnected() {
                    let connectedPeers = await cloudTransport.queryConnectedPeers()
                    // Format device IDs with names for logging
                    let devicesWithNames = connectedPeers.map { peer in
                        if let name = peer.name {
                            return "\(peer.deviceId) (\(name))"
                        }
                        return peer.deviceId
                    }
                    logger.info("☁️ [ConnectionStatusProber] Cloud query returned \(connectedPeers.count) connected devices: \(devicesWithNames)")
                    cloudConnectedDeviceIds = Set(connectedPeers.map { $0.deviceId })
                }
            }
        
        // Check network connectivity - update status immediately if disconnected
        if !hasNetworkConnectivity {
            transportManager.updateConnectionState(.disconnected)
        } else {
            // Verify network with HTTP check
            let hasNetwork = await checkNetworkConnectivity()
            if !hasNetwork {
                hasNetworkConnectivity = false
                transportManager.updateConnectionState(.disconnected)
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
                transportManager.updateConnectionState(.connectedCloud)
            } else if !isConnecting {
                // Try to connect to cloud if not already connecting
                isConnecting = true
                transportManager.updateConnectionState(.connectingCloud)
                
                // Actually connect to cloud relay (not just check health)
                if let transportProvider = transportProvider as? DefaultTransportProvider {
                    let cloudTransport = transportProvider.getCloudTransport()
                    do {
                        try await cloudTransport.connect()
                        transportManager.updateConnectionState(.connectedCloud)
                        logger.info("connect", "✅ [ConnectionStatusProber] Successfully connected to cloud relay\n")
                        // Trigger another probe immediately after cloud connection to query connected peers
                        // This ensures we detect devices that are already connected via cloud
                        logger.info("🔄", "[ConnectionStatusProber] Triggering probe after cloud connection\n")
                        await probeConnections()
                    } catch {
                        // Connection failed, check if we have LAN connections
                        let hasLanConnection = !onlineDeviceIds.isEmpty || !discoveredDeviceIds.isEmpty
                        transportManager.updateConnectionState(hasLanConnection ? .connectedLan : .disconnected)
                        logger.info("error", "❌ [ConnectionStatusProber] Cloud connection failed: \(error.localizedDescription)\n")
                    }
                } else {
                    // No transport provider, check server health as fallback
                    let serverReachable = await checkServerHealth()
                    if serverReachable {
                        transportManager.updateConnectionState(.connectedCloud)
                    } else {
                        // No cloud, check if we have LAN connections
                        let hasLanConnection = !onlineDeviceIds.isEmpty || !discoveredDeviceIds.isEmpty
                        transportManager.updateConnectionState(hasLanConnection ? .connectedLan : .disconnected)
                    }
                }
                isConnecting = false
            }
        }
        
        // Get current connection state to determine if server is available
        let currentConnectionState = transportManager.connectionState
        
        // Update status for each paired device - MIRROR ANDROID LOGIC
        for device in pairedDevices {
            // Check for active connection (case-insensitive matching)
            let hasActiveConnection = onlineDeviceIds.contains(device.id) || 
                onlineDeviceIds.contains { $0.lowercased() == device.id.lowercased() }
            
            // Check if discovered (case-insensitive matching)
            let isDiscovered = discoveredDeviceIds.contains(device.id) || 
                discoveredDeviceIds.contains { $0.lowercased() == device.id.lowercased() }
            
            // Update device with discovery information if found
            if isDiscovered {
                let discoveredPeers = transportManager.lanDiscoveredPeers()
                // Match by device ID (case-insensitive)
                if let peer = discoveredPeers.first(where: { peer in
                    if let peerDeviceId = peer.endpoint.metadata["device_id"] {
                        return peerDeviceId.lowercased() == device.id.lowercased()
                    }
                    return false
                }) {
                    // Update device with discovery info
                    let updatedDevice = device.updating(from: peer)
                    await transportManager.registerPairedDevice(updatedDevice)
                }
            }
            
            // Get stored transport status for this device (matches Android's lastSuccessfulTransport)
            // Note: TransportManager stores transport by service name/identifier, which may differ from device ID
            // We try multiple lookup strategies to find the stored transport status
            var deviceTransport: TransportChannel? = nil
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
            
            // Check if device is connected via cloud relay (from query result)
            let isConnectedViaCloud = cloudConnectedDeviceIds.contains(device.id) ||
                cloudConnectedDeviceIds.contains { $0.lowercased() == device.id.lowercased() }
            
            // Determine device online status - REAL-TIME STATUS (no grace period):
            // Devices are only online if they are:
            //   1. Discovered on LAN (active discovery) - LAN discovery means network is available
            //   2. Have an active WebSocket connection (LAN or cloud)
            //   3. Are in the cloud-connected peers list (device connected via cloud relay)
            //   4. Have cloud transport AND server is connected via cloud (fallback for devices that haven't been queried yet)
            let isOnline: Bool
            if isDiscovered || hasActiveConnection || isConnectedViaCloud {
                // Device is discovered on LAN, has active connection, or is connected via cloud relay - definitely online
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
            
            // Only update if status changed
            if device.isOnline != isOnline {
                logger.info("update", "🔄 [ConnectionStatusProber] Updating device \(device.name) status: \(device.isOnline) → \(isOnline) (connection=\(hasActiveConnection), discovered=\(isDiscovered), cloudConnected=\(isConnectedViaCloud), transport=\(deviceTransport?.rawValue ?? "none"), connectionState=\(currentConnectionState))\n")
                await transportManager.updateDeviceOnlineStatus(deviceId: device.id, isOnline: isOnline)
            }
        }
        
        // Probe complete - no logging needed
    }
}
