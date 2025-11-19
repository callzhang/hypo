import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(os)
import os
#endif

/// Periodically probes connection status to paired devices and updates their online status.
/// Checks on app launch, when app becomes active, and every 10 minutes.
@MainActor
public final class ConnectionStatusProber {
    private weak var historyViewModel: ClipboardHistoryViewModel?
    private let webSocketServer: LanWebSocketServer
    private weak var transportManager: TransportManager?
    private let transportProvider: TransportProvider?
    private var periodicTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var isProbing = false
    private var isConnecting = false
    
    #if canImport(os)
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "connection-prober")
    #endif
    
    public init(historyViewModel: ClipboardHistoryViewModel, webSocketServer: LanWebSocketServer, transportManager: TransportManager, transportProvider: TransportProvider? = nil) {
        self.historyViewModel = historyViewModel
        self.webSocketServer = webSocketServer
        self.transportManager = transportManager
        self.transportProvider = transportProvider
    }
    
    deinit {
        // Cancel tasks in deinit (non-isolated context)
        periodicTask?.cancel()
        connectionTask?.cancel()
    }
    
    /// Start periodic connection status probing
    public func start() {
        stop() // Stop any existing task
        
        let msg = "🔍 [ConnectionStatusProber] Started - will probe every 30 seconds\n"
        print(msg)
        try? msg.appendToFile(path: "/tmp/hypo_debug.log")
        
        // Initial probe on launch
        Task { @MainActor in
            let taskMsg = "🚀 [ConnectionStatusProber] Starting initial probe task\n"
            print(taskMsg)
            try? taskMsg.appendToFile(path: "/tmp/hypo_debug.log")
            await probeConnections()
            let taskDoneMsg = "✅ [ConnectionStatusProber] Initial probe task completed\n"
            print(taskDoneMsg)
            try? taskDoneMsg.appendToFile(path: "/tmp/hypo_debug.log")
        }
        
        // Periodic probe every 30 seconds (similar to Android's frequent checks)
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000) // 30 seconds
                guard !Task.isCancelled else { break }
                await self?.probeConnections()
            }
        }
        
        #if canImport(os)
        logger.info("Connection status prober started")
        #endif
    }
    
    /// Stop periodic probing
    public func stop() {
        periodicTask?.cancel()
        periodicTask = nil
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
    
    /// Check server health via HTTP (fallback when WebSocket fails)
    private func checkServerHealth() async -> Bool {
        guard let url = URL(string: "https://hypo.fly.dev/health") else {
            return false
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            let errorMsg = "🏥 [ConnectionStatusProber] Health check failed: \(error.localizedDescription)\n"
            print(errorMsg)
            try? errorMsg.appendToFile(path: "/tmp/hypo_debug.log")
            return false
        }
    }
    
    /// Probe connection status for all paired devices
    private func probeConnections() async {
        guard !isProbing else {
            print("⏭️ [ConnectionStatusProber] Probe already in progress, skipping")
            return
        }
        
        isProbing = true
        defer { isProbing = false }
        
        #if canImport(os)
        logger.info("Probing connection status for paired devices")
        #endif
        let probeMsg = "🔍 [ConnectionStatusProber] Probing connection status...\n"
        print(probeMsg)
        try? probeMsg.appendToFile(path: "/tmp/hypo_debug.log")
        
        // Get all paired devices from ViewModel
        guard let historyViewModel = historyViewModel else {
            print("⚠️ [ConnectionStatusProber] HistoryViewModel is nil, cannot probe")
            return
        }
        
        let pairedDevices = historyViewModel.pairedDevices
        
        // Get active connections from WebSocket server
        let activeConnectionIds = webSocketServer.activeConnections()
        let foundMsg = "🔍 [ConnectionStatusProber] Found \(activeConnectionIds.count) active WebSocket connections\n"
        print(foundMsg)
        try? foundMsg.appendToFile(path: "/tmp/hypo_debug.log")
        if activeConnectionIds.count > 0 {
            let idsMsg = "🔍 [ConnectionStatusProber] Active connection IDs: \(activeConnectionIds.map { $0.uuidString.prefix(8) }.joined(separator: ", "))\n"
            print(idsMsg)
            try? idsMsg.appendToFile(path: "/tmp/hypo_debug.log")
        }
        
        // Get device IDs from active connections
        var onlineDeviceIds = Set<String>()
        let checkMsg = "🔍 [ConnectionStatusProber] Checking \(activeConnectionIds.count) active connections for device IDs\n"
        print(checkMsg)
        try? checkMsg.appendToFile(path: "/tmp/hypo_debug.log")
        for connectionId in activeConnectionIds {
            if let metadata = webSocketServer.connectionMetadata(for: connectionId) {
                let metaMsg = "🔍 [ConnectionStatusProber] Connection \(connectionId.uuidString.prefix(8)) metadata: deviceId=\(metadata.deviceId ?? "nil")\n"
                print(metaMsg)
                try? metaMsg.appendToFile(path: "/tmp/hypo_debug.log")
                if let deviceId = metadata.deviceId {
                    onlineDeviceIds.insert(deviceId)
                    let onlineMsg = "✅ [ConnectionStatusProber] Device \(deviceId) has active WebSocket connection\n"
                    print(onlineMsg)
                    try? onlineMsg.appendToFile(path: "/tmp/hypo_debug.log")
                } else {
                    let noIdMsg = "⚠️ [ConnectionStatusProber] Connection \(connectionId.uuidString.prefix(8)) has no deviceId in metadata\n"
                    print(noIdMsg)
                    try? noIdMsg.appendToFile(path: "/tmp/hypo_debug.log")
                }
            } else {
                let noMetaMsg = "⚠️ [ConnectionStatusProber] Connection \(connectionId.uuidString.prefix(8)) has no metadata\n"
                print(noMetaMsg)
                try? noMetaMsg.appendToFile(path: "/tmp/hypo_debug.log")
            }
        }
        
        // Also check discovered peers via Bonjour (for devices that are discovered but may not have connected yet)
        var discoveredDeviceIds = Set<String>()
        if let transportManager = transportManager {
            let discoveredPeers = transportManager.lanDiscoveredPeers()
            print("🔍 [ConnectionStatusProber] Found \(discoveredPeers.count) discovered peers via Bonjour")
            
            for peer in discoveredPeers {
                // Try to extract device ID from peer endpoint metadata
                if let deviceId = peer.endpoint.metadata["device_id"] {
                    discoveredDeviceIds.insert(deviceId)
                    print("✅ [ConnectionStatusProber] Device \(deviceId) is discovered via Bonjour")
                } else {
                    // Fallback: use service name if it matches a paired device ID
                    for device in pairedDevices {
                        if peer.serviceName.contains(device.id) || device.id.contains(peer.serviceName) {
                            discoveredDeviceIds.insert(device.id)
                            print("✅ [ConnectionStatusProber] Device \(device.id) is discovered via Bonjour (matched by service name)")
                            break
                        }
                    }
                }
            }
        }
        
        // Check cloud transport connection status
        // Get the actual connection state of the cloud transport
        var cloudTransportConnected = false
        if let transportProvider = transportProvider as? DefaultTransportProvider {
            let cloudTransport = transportProvider.getCloudTransport()
            cloudTransportConnected = cloudTransport.isConnected()
            if cloudTransportConnected {
                print("☁️ [ConnectionStatusProber] Cloud relay transport is connected")
            } else {
                print("☁️ [ConnectionStatusProber] Cloud relay transport is not connected")
            }
        } else if transportProvider != nil {
            // Fallback: if we have a provider but can't check connection, assume available
            cloudTransportConnected = true
            print("☁️ [ConnectionStatusProber] Cloud relay transport available (connection status unknown)")
        }
        
        // Always try to connect to cloud if not connected (to show server availability)
        // This ensures the connection state reflects whether the server is reachable
        if !cloudTransportConnected {
            if let transportProvider = transportProvider as? DefaultTransportProvider {
                let cloudTransport = transportProvider.getCloudTransport()
                let currentPreference = transportManager?.currentPreference() ?? .lanFirst
                let connectMsg = "☁️ [ConnectionStatusProber] Attempting to connect to cloud relay (paired devices: \(pairedDevices.count), preference: \(currentPreference))\n"
                print(connectMsg)
                try? connectMsg.appendToFile(path: "/tmp/hypo_debug.log")
                
                // Check if already connected or connecting
                if cloudTransport.isConnected() {
                    let alreadyMsg = "☁️ [ConnectionStatusProber] Cloud relay already connected\n"
                    print(alreadyMsg)
                    try? alreadyMsg.appendToFile(path: "/tmp/hypo_debug.log")
                    await transportManager?.updateConnectionState(.connectedCloud)
                } else if isConnecting {
                    let inProgressMsg = "⏳ [ConnectionStatusProber] Connection already in progress, skipping\n"
                    print(inProgressMsg)
                    try? inProgressMsg.appendToFile(path: "/tmp/hypo_debug.log")
                } else {
                    // Mark as connecting to prevent concurrent attempts
                    isConnecting = true
                    
                    // Update connection state to connecting
                    await transportManager?.updateConnectionState(.connectingCloud)
                    
                    // First, do a simple HTTP health check to verify server is reachable
                    // This gives us a quick way to show server availability even if WebSocket fails
                    let healthCheckMsg = "🏥 [ConnectionStatusProber] Checking server health via HTTP\n"
                    print(healthCheckMsg)
                    try? healthCheckMsg.appendToFile(path: "/tmp/hypo_debug.log")
                    
                    let serverReachable = await checkServerHealth()
                    if serverReachable {
                        let reachableMsg = "✅ [ConnectionStatusProber] Server is reachable via HTTP\n"
                        print(reachableMsg)
                        try? reachableMsg.appendToFile(path: "/tmp/hypo_debug.log")
                        // Show as connected even if WebSocket fails - server is available
                        await transportManager?.updateConnectionState(.connectedCloud)
                        isConnecting = false
                    } else {
                        // Try WebSocket connection
                        // CRITICAL: Retain a strong reference to the cloud transport
                        // to prevent it from being deallocated during connection
                        let retainedTransport = cloudTransport
                        
                        // Store the connection task to prevent cancellation
                        // Use Task.detached to make it independent of the probe task
                        let taskCreatedMsg = "🎯 [ConnectionStatusProber] Creating connection Task (transport retained)\n"
                        print(taskCreatedMsg)
                        try? taskCreatedMsg.appendToFile(path: "/tmp/hypo_debug.log")
                        
                        connectionTask = Task.detached { @MainActor [weak self] in
                            // Retain transport in the task to prevent deallocation
                            let _ = retainedTransport
                            let taskStartedMsg = "🎯 [ConnectionStatusProber] Connection Task started executing\n"
                            print(taskStartedMsg)
                            try? taskStartedMsg.appendToFile(path: "/tmp/hypo_debug.log")
                            
                            // Check if task is cancelled before starting
                            if Task.isCancelled {
                                let cancelledMsg = "⚠️ [ConnectionStatusProber] Task already cancelled before execution\n"
                                print(cancelledMsg)
                                try? cancelledMsg.appendToFile(path: "/tmp/hypo_debug.log")
                                return
                            }
                            
                            guard let self = self else {
                                // Can't access isConnecting without self, but task will be cleaned up anyway
                                return
                            }
                            defer {
                                // Clear the connection flag when done
                                self.isConnecting = false
                                self.connectionTask = nil
                            }
                            do {
                                let beforeConnectMsg = "🎯 [ConnectionStatusProber] About to call cloudTransport.connect()\n"
                                print(beforeConnectMsg)
                                try? beforeConnectMsg.appendToFile(path: "/tmp/hypo_debug.log")
                                
                                try await cloudTransport.connect()
                                let successMsg = "✅ [ConnectionStatusProber] Successfully connected to cloud relay\n"
                                print(successMsg)
                                try? successMsg.appendToFile(path: "/tmp/hypo_debug.log")
                                
                                // Update connection state to connected
                                await self.transportManager?.updateConnectionState(.connectedCloud)
                                
                                // Trigger another probe after connection to update device status
                                await self.probeConnections()
                            } catch {
                                let errorMsg = "❌ [ConnectionStatusProber] Failed to connect to cloud relay: \(error.localizedDescription)\n"
                                print(errorMsg)
                                try? errorMsg.appendToFile(path: "/tmp/hypo_debug.log")
                                
                                // Check if LAN is available as fallback
                                let hasLanConnection = !onlineDeviceIds.isEmpty || !discoveredDeviceIds.isEmpty
                                if hasLanConnection {
                                    await self.transportManager?.updateConnectionState(.connectedLan)
                                } else {
                                    // No connections available - server is offline
                                    await self.transportManager?.updateConnectionState(.idle)
                                }
                            }
                        }
                    }
                }
            } else {
                // No transport provider - check LAN only
                let hasLanConnection = !onlineDeviceIds.isEmpty || !discoveredDeviceIds.isEmpty
                if hasLanConnection {
                    await transportManager?.updateConnectionState(.connectedLan)
                } else {
                    await transportManager?.updateConnectionState(.idle)
                }
            }
        } else {
            // Cloud is already connected, update connection state
            await transportManager?.updateConnectionState(.connectedCloud)
        }
        
        // Update status for each paired device
        // A device is online if it has an active LAN connection OR is discovered via Bonjour OR cloud is connected
        let checkDevicesMsg = "🔍 [ConnectionStatusProber] Checking \(pairedDevices.count) paired devices\n"
        print(checkDevicesMsg)
        try? checkDevicesMsg.appendToFile(path: "/tmp/hypo_debug.log")
        let onlineIdsMsg = "🔍 [ConnectionStatusProber] Online device IDs: \(onlineDeviceIds)\n"
        print(onlineIdsMsg)
        try? onlineIdsMsg.appendToFile(path: "/tmp/hypo_debug.log")
        let discoveredIdsMsg = "🔍 [ConnectionStatusProber] Discovered device IDs: \(discoveredDeviceIds)\n"
        print(discoveredIdsMsg)
        try? discoveredIdsMsg.appendToFile(path: "/tmp/hypo_debug.log")
        for device in pairedDevices {
            let hasActiveConnection = onlineDeviceIds.contains(device.id)
            let isDiscovered = discoveredDeviceIds.contains(device.id)
            
            // Check if device was recently seen (within last 2 minutes)
            // This provides a grace period for devices that were just connected
            let timeSinceLastSeen = Date().timeIntervalSince(device.lastSeen)
            let wasRecentlySeen = timeSinceLastSeen < 120.0 // 2 minutes
            
            // Device is online if:
            // 1. Has active connection, OR
            // 2. Is discovered via Bonjour, OR
            // 3. Cloud transport is connected (all devices accessible via cloud), OR
            // 4. Was recently seen (grace period for recently connected devices)
            let isOnline = hasActiveConnection || isDiscovered || cloudTransportConnected || wasRecentlySeen
            
            let deviceStatusMsg = "🔍 [ConnectionStatusProber] Device \(device.name) (\(device.id.prefix(20))...): hasConnection=\(hasActiveConnection), isDiscovered=\(isDiscovered), cloudConnected=\(cloudTransportConnected), recentlySeen=\(wasRecentlySeen) (lastSeen: \(Int(timeSinceLastSeen))s ago) → isOnline=\(isOnline)\n"
            print(deviceStatusMsg)
            try? deviceStatusMsg.appendToFile(path: "/tmp/hypo_debug.log")
            
            // Only update if status changed
            if device.isOnline != isOnline {
                let updateMsg = "🔄 [ConnectionStatusProber] Updating device \(device.name) status: \(device.isOnline) → \(isOnline) (connection=\(hasActiveConnection), discovered=\(isDiscovered), cloud=\(cloudTransportConnected), recentlySeen=\(wasRecentlySeen))\n"
                print(updateMsg)
                try? updateMsg.appendToFile(path: "/tmp/hypo_debug.log")
                await historyViewModel.updateDeviceOnlineStatus(deviceId: device.id, isOnline: isOnline)
            } else {
                let unchangedMsg = "ℹ️ [ConnectionStatusProber] Device \(device.name) status unchanged: \(isOnline) (connection=\(hasActiveConnection), discovered=\(isDiscovered), cloud=\(cloudTransportConnected), recentlySeen=\(wasRecentlySeen))\n"
                print(unchangedMsg)
                try? unchangedMsg.appendToFile(path: "/tmp/hypo_debug.log")
            }
        }
        
        let completeMsg = "✅ [ConnectionStatusProber] Probe complete - \(onlineDeviceIds.count) devices with active LAN connections, \(discoveredDeviceIds.count) devices discovered, cloud transport: \(cloudTransportConnected ? "connected" : "not connected")\n"
        print(completeMsg)
        try? completeMsg.appendToFile(path: "/tmp/hypo_debug.log")
    }
}

