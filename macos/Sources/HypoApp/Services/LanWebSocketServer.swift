import Foundation
import Network
#if canImport(os)
import os
#endif

public enum WebSocketMessageType {
    case pairing
    case clipboard
    case unknown
}

public protocol LanWebSocketServerDelegate: AnyObject {
    func server(_ server: LanWebSocketServer, didReceivePairingChallenge challenge: PairingChallengeMessage, from connection: UUID)
    func server(_ server: LanWebSocketServer, didReceiveClipboardData data: Data, from connection: UUID)
    func server(_ server: LanWebSocketServer, didAcceptConnection id: UUID)
    func server(_ server: LanWebSocketServer, didCloseConnection id: UUID)
}

@MainActor
public final class LanWebSocketServer {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var connectionMetadata: [UUID: ConnectionMetadata] = [:]
    public weak var delegate: LanWebSocketServerDelegate?
    
    #if canImport(os)
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "lan-server")
    #endif
    
    private struct ConnectionMetadata {
        let deviceId: String?
        let connectedAt: Date
    }
    
    public init() {}
    
    public func start(port: Int) throws {
        print("🚀 [LanWebSocketServer] Starting WebSocket server on port \(port)")
        #if canImport(os)
        logger.info("Starting WebSocket server on port \(port)")
        #endif
        
        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = false  // Allow connections from LAN
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        } catch {
            #if canImport(os)
            logger.error("Failed to create listener: \(error.localizedDescription)")
            #endif
            throw error
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }
        
        listener?.start(queue: .main)
    }
    
    public func stop() {
        #if canImport(os)
        logger.info("Stopping WebSocket server")
        #endif
        
        listener?.cancel()
        listener = nil
        
        for (id, connection) in connections {
            connection.cancel()
            delegate?.server(self, didCloseConnection: id)
        }
        connections.removeAll()
        connectionMetadata.removeAll()
    }
    
    public func send(_ data: Data, to connectionId: UUID) throws {
        guard let connection = connections[connectionId] else {
            throw NSError(domain: "LanWebSocketServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Connection not found"
            ])
        }
        
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error = error {
                #if canImport(os)
                self.logger.error("Send error: \(error.localizedDescription)")
                #endif
            }
        })
    }
    
    public func sendToAll(_ data: Data) {
        for (id, _) in connections {
            try? send(data, to: id)
        }
    }
    
    public func activeConnections() -> [UUID] {
        Array(connections.keys)
    }
    
    public func sendPairingAck(_ ack: PairingAckMessage, to connectionId: UUID) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(ack)
        try send(data, to: connectionId)
        
        #if canImport(os)
        logger.info("Sent pairing ACK to connection: \(connectionId.uuidString)")
        #endif
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connectionMetadata[id] = ConnectionMetadata(deviceId: nil, connectedAt: Date())
        
        #if canImport(os)
        logger.info("New connection: \(id.uuidString)")
        #endif
        
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state, for: id)
            }
        }
        
        connection.start(queue: .main)
        receiveMessage(from: connection, id: id)
        
        delegate?.server(self, didAcceptConnection: id)
    }
    
    private func receiveMessage(from connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }
                
                if let error = error {
                    #if canImport(os)
                    self.logger.error("Receive error: \(error.localizedDescription)")
                    #endif
                    self.closeConnection(id)
                    return
                }
                
                if let content = content, !content.isEmpty {
                    self.handleReceivedData(content, from: id)
                }
                
                // Continue receiving
                if self.connections[id] != nil {
                    self.receiveMessage(from: connection, id: id)
                }
            }
        }
    }
    
    private func handleReceivedData(_ data: Data, from connectionId: UUID) {
        let messageType = detectMessageType(data)
        
        switch messageType {
        case .pairing:
            handlePairingMessage(data, from: connectionId)
        case .clipboard:
            delegate?.server(self, didReceiveClipboardData: data, from: connectionId)
        case .unknown:
            #if canImport(os)
            logger.warning("Received unknown message type from \(connectionId.uuidString)")
            #endif
        }
    }
    
    private func detectMessageType(_ data: Data) -> WebSocketMessageType {
        // Try to decode as JSON to peek at the structure
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown
        }
        
        // Pairing messages have challenge_id
        if json["challenge_id"] != nil {
            return .pairing
        }
        
        // Clipboard messages have type field
        if json["type"] != nil {
            return .clipboard
        }
        
        return .unknown
    }
    
    private func handlePairingMessage(_ data: Data, from connectionId: UUID) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        
        do {
            let challenge = try decoder.decode(PairingChallengeMessage.self, from: data)
            #if canImport(os)
            logger.info("Received pairing challenge from device: \(challenge.androidDeviceName)")
            #endif
            delegate?.server(self, didReceivePairingChallenge: challenge, from: connectionId)
        } catch {
            #if canImport(os)
            logger.error("Failed to decode pairing message: \(error.localizedDescription)")
            #endif
        }
    }
    
    private func handleListenerState(_ state: NWListener.State) {
        #if canImport(os)
        switch state {
        case .ready:
            logger.info("WebSocket server ready")
        case .failed(let error):
            logger.error("WebSocket server failed: \(error.localizedDescription)")
        case .cancelled:
            logger.info("WebSocket server cancelled")
        default:
            logger.debug("WebSocket server state: \(String(describing: state))")
        }
        #endif
    }
    
    private func handleConnectionState(_ state: NWConnection.State, for id: UUID) {
        switch state {
        case .ready:
            #if canImport(os)
            logger.info("Connection ready: \(id.uuidString)")
            #endif
        case .failed(let error):
            #if canImport(os)
            logger.error("Connection failed: \(error.localizedDescription)")
            #endif
            closeConnection(id)
        case .cancelled:
            closeConnection(id)
        default:
            break
        }
    }
    
    private func closeConnection(_ id: UUID) {
        connections[id]?.cancel()
        connections.removeValue(forKey: id)
        connectionMetadata.removeValue(forKey: id)
        delegate?.server(self, didCloseConnection: id)
        
        #if canImport(os)
        logger.info("Connection closed: \(id.uuidString)")
        #endif
    }
}

