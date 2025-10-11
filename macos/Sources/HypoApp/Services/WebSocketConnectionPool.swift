import Foundation
import Combine
import os.log
import Network

/// WebSocket connection pool for optimizing network resource usage
public actor WebSocketConnectionPool {
    
    struct PooledConnection {
        let id: UUID
        let webSocket: URLSessionWebSocketTask
        let endpoint: Endpoint
        let lastUsed: Date
        var isActive: Bool
        var messageCount: Int
        
        init(webSocket: URLSessionWebSocketTask, endpoint: Endpoint) {
            self.id = UUID()
            self.webSocket = webSocket
            self.endpoint = endpoint
            self.lastUsed = Date()
            self.isActive = true
            self.messageCount = 0
        }
    }
    
    public struct Endpoint: Hashable {
        let host: String
        let port: Int
        let path: String
        let isSecure: Bool
        
        var url: URL? {
            var components = URLComponents()
            components.scheme = isSecure ? "wss" : "ws"
            components.host = host
            components.port = port
            components.path = path
            return components.url
        }
    }
    
    private var activeConnections: [UUID: PooledConnection] = [:]
    private var availableConnections: [Endpoint: [PooledConnection]] = [:]
    private let maxConnectionsPerEndpoint: Int
    private let connectionTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    private let maxMessageCount: Int
    
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "connection-pool")
    private var cleanupTask: Task<Void, Never>?
    
    public init(
        maxConnectionsPerEndpoint: Int = 3,
        connectionTimeout: TimeInterval = 10.0,
        idleTimeout: TimeInterval = 300.0, // 5 minutes
        maxMessageCount: Int = 1000
    ) {
        self.maxConnectionsPerEndpoint = maxConnectionsPerEndpoint
        self.connectionTimeout = connectionTimeout
        self.idleTimeout = idleTimeout
        self.maxMessageCount = maxMessageCount
        
        startCleanupTask()
    }
    
    deinit {
        cleanupTask?.cancel()
    }
    
    // MARK: - Public API
    
    public func acquireConnection(to endpoint: Endpoint) async throws -> (UUID, URLSessionWebSocketTask) {
        // Try to reuse an available connection
        if let reusableConnection = getAvailableConnection(for: endpoint) {
            logger.debug("Reusing connection to \(endpoint.host):\(endpoint.port)")
            return (reusableConnection.id, reusableConnection.webSocket)
        }
        
        // Create new connection if we haven't reached the limit
        if getConnectionCount(for: endpoint) < maxConnectionsPerEndpoint {
            let connection = try await createNewConnection(to: endpoint)
            logger.debug("Created new connection to \(endpoint.host):\(endpoint.port)")
            return (connection.id, connection.webSocket)
        }
        
        // Wait for an existing connection to become available
        logger.debug("Waiting for available connection to \(endpoint.host):\(endpoint.port)")
        return try await waitForAvailableConnection(to: endpoint)
    }
    
    public func releaseConnection(_ connectionId: UUID) {
        guard let connection = activeConnections[connectionId] else { return }
        
        var updatedConnection = connection
        updatedConnection.isActive = false
        updatedConnection.lastUsed = Date()
        
        activeConnections[connectionId] = updatedConnection
        
        // Move to available pool if connection is still healthy
        if isConnectionHealthy(updatedConnection) {
            availableConnections[connection.endpoint, default: []].append(updatedConnection)
            logger.debug("Released connection \(connectionId) to pool")
        } else {
            closeConnection(connectionId)
            logger.debug("Closed unhealthy connection \(connectionId)")
        }
    }
    
    public func incrementMessageCount(_ connectionId: UUID) {
        guard var connection = activeConnections[connectionId] else { return }
        connection.messageCount += 1
        activeConnections[connectionId] = connection
        
        // Rotate connection if it has handled too many messages
        if connection.messageCount >= maxMessageCount {
            logger.debug("Rotating connection \(connectionId) after \(connection.messageCount) messages")
            closeConnection(connectionId)
        }
    }
    
    public func closeConnection(_ connectionId: UUID) {
        guard let connection = activeConnections.removeValue(forKey: connectionId) else { return }
        
        connection.webSocket.cancel(with: .goingAway, reason: nil)
        
        // Remove from available connections
        if var endpointConnections = availableConnections[connection.endpoint] {
            endpointConnections.removeAll { $0.id == connectionId }
            if endpointConnections.isEmpty {
                availableConnections.removeValue(forKey: connection.endpoint)
            } else {
                availableConnections[connection.endpoint] = endpointConnections
            }
        }
        
        logger.debug("Closed connection \(connectionId)")
    }
    
    public func closeAllConnections() {
        let connectionIds = Array(activeConnections.keys)
        for connectionId in connectionIds {
            closeConnection(connectionId)
        }
        logger.debug("Closed all connections")
    }
    
    public func getPoolStats() -> (active: Int, available: Int, totalEndpoints: Int) {
        let activeCount = activeConnections.values.filter(\.isActive).count
        let availableCount = availableConnections.values.flatMap { $0 }.count
        let endpointCount = availableConnections.keys.count
        return (active: activeCount, available: availableCount, totalEndpoints: endpointCount)
    }
    
    // MARK: - Private Methods
    
    private func getAvailableConnection(for endpoint: Endpoint) -> PooledConnection? {
        guard var endpointConnections = availableConnections[endpoint],
              !endpointConnections.isEmpty else { return nil }
        
        let connection = endpointConnections.removeFirst()
        if endpointConnections.isEmpty {
            availableConnections.removeValue(forKey: endpoint)
        } else {
            availableConnections[endpoint] = endpointConnections
        }
        
        var activeConnection = connection
        activeConnection.isActive = true
        activeConnections[connection.id] = activeConnection
        
        return activeConnection
    }
    
    private func getConnectionCount(for endpoint: Endpoint) -> Int {
        let activeCount = activeConnections.values.filter { $0.endpoint == endpoint }.count
        let availableCount = availableConnections[endpoint]?.count ?? 0
        return activeCount + availableCount
    }
    
    private func createNewConnection(to endpoint: Endpoint) async throws -> PooledConnection {
        guard let url = endpoint.url else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = connectionTimeout
        
        let session = URLSession.shared
        let webSocket = session.webSocketTask(with: request)
        
        let connection = PooledConnection(webSocket: webSocket, endpoint: endpoint)
        activeConnections[connection.id] = connection
        
        webSocket.resume()
        
        return connection
    }
    
    private func waitForAvailableConnection(to endpoint: Endpoint) async throws -> (UUID, URLSessionWebSocketTask) {
        // Implement a simple polling mechanism with exponential backoff
        var retryCount = 0
        let maxRetries = 10
        
        while retryCount < maxRetries {
            if let connection = getAvailableConnection(for: endpoint) {
                return (connection.id, connection.webSocket)
            }
            
            let delay = min(pow(2.0, Double(retryCount)) * 0.1, 2.0) // Max 2 second delay
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            retryCount += 1
        }
        
        throw URLError(.timedOut)
    }
    
    private func isConnectionHealthy(_ connection: PooledConnection) -> Bool {
        // Check if connection is too old or has handled too many messages
        let age = Date().timeIntervalSince(connection.lastUsed)
        return age < idleTimeout && 
               connection.messageCount < maxMessageCount &&
               connection.webSocket.state == .running
    }
    
    private func startCleanupTask() {
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.performCleanup()
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute
            }
        }
    }
    
    private func performCleanup() {
        let now = Date()
        var connectionsToClose: [UUID] = []
        
        // Check for idle or unhealthy connections
        for (id, connection) in activeConnections {
            if !connection.isActive {
                let idleTime = now.timeIntervalSince(connection.lastUsed)
                if idleTime > idleTimeout || !isConnectionHealthy(connection) {
                    connectionsToClose.append(id)
                }
            }
        }
        
        // Close idle connections
        for connectionId in connectionsToClose {
            closeConnection(connectionId)
        }
        
        // Clean up available connections that are no longer healthy
        for (endpoint, connections) in availableConnections {
            let healthyConnections = connections.filter(isConnectionHealthy)
            if healthyConnections.count != connections.count {
                availableConnections[endpoint] = healthyConnections
                logger.debug("Cleaned up \(connections.count - healthyConnections.count) stale connections for \(endpoint.host)")
            }
        }
        
        if !connectionsToClose.isEmpty {
            let stats = getPoolStats()
            logger.debug("Cleanup completed: active=\(stats.active), available=\(stats.available), endpoints=\(stats.totalEndpoints)")
        }
    }
}