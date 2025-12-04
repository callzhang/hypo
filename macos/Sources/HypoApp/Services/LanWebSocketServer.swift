import Foundation
import Network
import CryptoKit
#if canImport(os)
import os
#endif
#if canImport(ifaddrs)
import ifaddrs
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
    private let logger = HypoLogger(category: "LanWebSocketServer")
    
    private final class ConnectionContext: @unchecked Sendable {
        let connection: NWConnection
        private var buffer = Data()
        // Protects buffer mutations so concurrent frame appends can't corrupt indices (Issue 7)
        private let bufferLock = NSLock()
        var upgraded = false
        var pendingClose = false  // Set to true when close frame is received, but keep connection open until data is depleted

        init(connection: NWConnection) {
            self.connection = connection
        }
        
        func appendToBuffer(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            bufferLock.lock()
            buffer.append(chunk)
            bufferLock.unlock()
        }
        
        func consumeHeader(upTo delimiter: Data) -> Data? {
            bufferLock.lock()
            defer { bufferLock.unlock() }
            guard let headerRange = buffer.range(of: delimiter) else { return nil }
            let headerData = buffer.subdata(in: 0..<headerRange.upperBound)
            buffer = Data(buffer[headerRange.upperBound...])
            return headerData
        }
        
        func snapshotBuffer() -> Data {
            bufferLock.lock()
            let copy = buffer
            bufferLock.unlock()
            return copy
        }
        
        func dropPrefix(_ length: Int) {
            guard length > 0 else { return }
            bufferLock.lock()
            if length >= buffer.count {
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.removeSubrange(0..<length)
            }
            bufferLock.unlock()
        }
    }

    private var listener: NWListener?
    private var connections: [UUID: ConnectionContext] = [:]
    private var connectionMetadata: [UUID: ConnectionMetadata] = [:]
    public weak var delegate: LanWebSocketServerDelegate?
    private var localDeviceId: String?  // macOS device ID for target filtering
    
    public func connectionMetadata(for connectionId: UUID) -> ConnectionMetadata? {
        connectionMetadata[connectionId]
    }
    
    public func updateConnectionMetadata(connectionId: UUID, deviceId: String) {
        if let existing = connectionMetadata[connectionId] {
            connectionMetadata[connectionId] = ConnectionMetadata(deviceId: deviceId, connectedAt: existing.connectedAt)
        } else {
            connectionMetadata[connectionId] = ConnectionMetadata(deviceId: deviceId, connectedAt: Date())
        }
    }
    
    private let frameCodec = TransportFrameCodec()
    private let handshakeDelimiter = Data("\r\n\r\n".utf8)
    private let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    
    public struct ConnectionMetadata {
        public let deviceId: String?
        public let connectedAt: Date
        
        public init(deviceId: String?, connectedAt: Date) {
            self.deviceId = deviceId
            self.connectedAt = connectedAt
        }
    }
    
    public init(localDeviceId: String? = nil) {
        self.localDeviceId = localDeviceId
    }
    
    public func setLocalDeviceId(_ deviceId: String) {
        self.localDeviceId = deviceId
    }
    
    public func start(port: Int) throws {
        logger.info("🚀 Starting WebSocket server on port \(port)")
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = false  // Allow connections from LAN
        
        // NWListener with just a port automatically binds to all interfaces (0.0.0.0)
        // This allows connections from any network interface (LAN, WiFi, etc.)
        // No explicit IPv4/IPv6 configuration needed - Network.framework handles this
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
            logger.info("📡 [LanWebSocketServer] Listener created on port \(port) - will accept connections from all interfaces (0.0.0.0:\(port))")
        } catch {
            logger.error("❌", "Failed to create listener: \(error.localizedDescription)")
            throw error
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            DispatchQueue.main.async {
                Task { @MainActor in
                    self.handleNewConnection(connection)
                }
            }
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            Task { @MainActor [self] in
                self.handleListenerState(state)
            }
        }
        
        listener?.start(queue: .main)
    }
    
    public func stop() {
        self.logger.info("🛑", "Stopping WebSocket server")
        
        listener?.cancel()
        listener = nil
        
        for (id, context) in connections {
            context.connection.cancel()
            delegate?.server(self, didCloseConnection: id)
        }
        connections.removeAll()
        connectionMetadata.removeAll()
    }
    
    public func send(_ data: Data, to connectionId: UUID) throws {
        #if canImport(os)
        logger.info("📤 [LanWebSocketServer] send() called: connectionId=\(connectionId.uuidString.prefix(8)), data=\(data.count) bytes")
        if let metadata = connectionMetadata[connectionId] {
            logger.info("📤 [LanWebSocketServer] Connection metadata: deviceId=\(metadata.deviceId ?? "nil")")
        } else {
            logger.warning("⚠️ [LanWebSocketServer] No metadata found for connection \(connectionId.uuidString.prefix(8))")
        }
        #endif
        guard let context = connections[connectionId] else {
            #if canImport(os)
            logger.error("❌ [LanWebSocketServer] Connection not found: \(connectionId.uuidString.prefix(8))")
            logger.error("❌ [LanWebSocketServer] Available connections: \(connections.keys.map { $0.uuidString.prefix(8) }.joined(separator: ", "))")
            #endif
            throw NSError(domain: "LanWebSocketServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Connection not found"
            ])
        }
        guard context.upgraded else {
            #if canImport(os)
            logger.error("❌ [LanWebSocketServer] Connection not upgraded: \(connectionId.uuidString.prefix(8))")
            #endif
            throw NSError(domain: "LanWebSocketServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Connection not upgraded"
            ])
        }
        #if canImport(os)
        logger.info("✅ [LanWebSocketServer] Sending frame: \(data.count) bytes to connection \(connectionId.uuidString.prefix(8))")
        #endif
        sendFrame(payload: data, opcode: 0x2, context: context) { error in
            if let error {
                #if canImport(os)
                self.logger.error("❌ [LanWebSocketServer] Send error: \(error.localizedDescription)")
                #endif
            } else {
                #if canImport(os)
                self.logger.info("✅ [LanWebSocketServer] Frame sent successfully to \(connectionId.uuidString.prefix(8))")
                #endif
            }
        }
    }
    
    public func sendToAll(_ data: Data) {
        for (id, _) in connections {
            try? send(data, to: id)
        }
    }
    
    public func activeConnections() -> [UUID] {
        let active = Array(connections.keys)
        logger.info("🔍 [LanWebSocketServer] activeConnections() called: \(active.count) connections")
        if active.count > 0 {
            for id in active {
                if let metadata = connectionMetadata[id] {
                    logger.info("🔍 [LanWebSocketServer] Connection \(id.uuidString.prefix(8)): deviceId=\(metadata.deviceId ?? "nil"), upgraded=\(connections[id]?.upgraded ?? false)")
                }
            }
        }
        return active
    }
    
    public func sendPairingAck(_ ack: PairingAckMessage, to connectionId: UUID) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(ack)
        
        // Send as text frame (not binary) so Android can parse it as JSON string
        guard let context = connections[connectionId], context.upgraded else {
            logger.error("❌ Connection not found or not upgraded: \(connectionId.uuidString.prefix(8))")
            throw NSError(domain: "LanWebSocketServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Connection not found"
            ])
        }
        sendFrame(payload: data, opcode: 0x1, context: context) { [weak self] error in
            guard let self = self else { return }
            if let error {
                self.logger.error("❌ ACK send error: \(error.localizedDescription)")
            }
        }
    }

    private func sendFrame(payload: Data, opcode: UInt8, context: ConnectionContext, completion: @escaping (Error?) -> Void) {
        var frame = Data()
        var firstByte: UInt8 = 0x80 // FIN = 1
        firstByte |= (opcode & 0x0F)
        frame.append(firstByte)
        let length = payload.count
        if length <= 125 {
            frame.append(UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(126)
            var value = UInt16(length).bigEndian
            withUnsafeBytes(of: &value) { frame.append(contentsOf: $0) }
        } else {
            frame.append(127)
            var value = UInt64(length).bigEndian
            withUnsafeBytes(of: &value) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        context.connection.send(content: frame, completion: .contentProcessed { error in
            completion(error)
        })
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        let context = ConnectionContext(connection: connection)
        connections[id] = context
        connectionMetadata[id] = ConnectionMetadata(deviceId: nil, connectedAt: Date())
        
        logger.info("🔌 New connection: \(id.uuidString.prefix(8))")
        
        // Check initial state - connection might already be ready
        if case .ready = connection.state {
            beginHandshake(for: id)
        }
        
        connection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
            Task { @MainActor [self] in
                switch state {
                case .ready:
                    self.logger.info("🔗 [LanWebSocketServer] Connection \(id.uuidString.prefix(8)) state: ready")
                    self.beginHandshake(for: id)
                case .failed(let error):
                    // Connection resets (error 54) are normal when clients disconnect abruptly
                    // Log as info/warning instead of error to reduce noise
                    let errorCode = (error as NSError).code
                    if errorCode == 54 { // Connection reset by peer
                        self.logger.info("🔌 [LanWebSocketServer] Connection \(id.uuidString.prefix(8)) reset by peer (client disconnected)")
                    } else {
                        self.logger.warning("⚠️ [LanWebSocketServer] Connection \(id.uuidString.prefix(8)) failed: \(error.localizedDescription)")
                    }
                    self.closeConnection(id)
                case .cancelled:
                    self.logger.info("🔌 [LanWebSocketServer] Connection \(id.uuidString.prefix(8)) cancelled by system")
                    self.closeConnection(id)
                case .waiting(let error):
                    self.logger.info("⏳ [LanWebSocketServer] Connection \(id.uuidString.prefix(8)) waiting: \(error.localizedDescription)")
                default:
                    self.logger.info("🟡 [LanWebSocketServer] Connection \(id.uuidString.prefix(8)) state: \(String(describing: state))")
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func beginHandshake(for connectionId: UUID) {
        logger.info("🤝  beginHandshake called for \(connectionId.uuidString.prefix(8))")
        guard let context = connections[connectionId] else {
            logger.info("⚠️  No context found for connection \(connectionId.uuidString.prefix(8))")
            return
        }
        receiveHandshakeChunk(for: connectionId, context: context)
    }

    private func receiveHandshakeChunk(for connectionId: UUID, context: ConnectionContext) {
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            Task { @MainActor [self] in
                guard let context = self.connections[connectionId] else { return }
                if let error = error {
                    #if canImport(os)
                    self.logger.error("Handshake receive error: \(error.localizedDescription)")
                    #endif
                    self.logger.info("❌  Handshake receive error: \(error.localizedDescription)")
                    self.closeConnection(connectionId)
                    return
                }
                if let data, !data.isEmpty {
                    self.logger.info("📥  Handshake data received: \(data.count) bytes")
                    context.appendToBuffer(data)
                    self.logger.info("📥  Data appended to buffer, calling processHandshakeBuffer")
                    let processed = self.processHandshakeBuffer(for: connectionId, context: context)
                    self.logger.info("📥  processHandshakeBuffer returned: \(processed)")
                    if processed {
                        self.logger.info("✅  Handshake processing complete, stopping receive loop")
                        return
                    } else {
                        self.logger.info("⏳  Handshake processing incomplete, continuing receive loop")
                        // Continue receiving even if isComplete is true (might have more data)
                        self.receiveHandshakeChunk(for: connectionId, context: context)
                        return
                    }
                }
                // Handle EOF (isComplete = true) during handshake
                // isComplete = true means this receive operation finished, not necessarily that connection is closed
                // Only close if we're sure the connection is actually closed (no more data possible)
                if isComplete {
                    let bufferSnapshot = context.snapshotBuffer()
                    if bufferSnapshot.isEmpty {
                        // If already upgraded, this is fine - just EOF, don't close
                        if context.upgraded {
                            self.logger.info("✅  Handshake already complete, EOF is normal")
                            return
                        }
                        // During handshake, isComplete with empty buffer might mean:
                        // 1. Connection is actually closed (client disconnected)
                        // 2. This receive operation finished but more data might come
                        // Be more tolerant - check connection state before closing
                        let connectionState = context.connection.state
                        self.logger.info("⚠️  Handshake receive completed without data and empty buffer (connection state: \(connectionState))")
                        // Check connection state - if it's still ready, continue receiving
                        if connectionState == .ready {
                            self.logger.info("⏳  Connection still ready, continuing to receive handshake data")
                            self.receiveHandshakeChunk(for: connectionId, context: context)
                            return
                        } else {
                            // Connection is not ready (failed, cancelled, etc.) - close it
                            self.logger.info("⚠️  Connection not ready (state: \(connectionState)), closing")
                            self.closeConnection(connectionId)
                            return
                        }
                    } else {
                        // Buffer has data but we didn't receive new data - try processing buffer one more time
                        self.logger.info("⚠️  Handshake receive completed but buffer has \(bufferSnapshot.count) bytes - processing buffer")
                        let processed = self.processHandshakeBuffer(for: connectionId, context: context)
                        if processed {
                            self.logger.info("✅  Handshake processing complete from buffer")
                            return
                        } else {
                            // If already upgraded, don't close - might be data frames mixed in
                            if context.upgraded {
                                self.logger.info("✅  Already upgraded, treating remaining buffer as data frames")
                                // Switch to frame processing
                                self.processFrameBuffer(for: connectionId, context: context)
                                self.receiveFrameChunk(for: connectionId, context: context)
                                return
                            }
                            // Handshake incomplete but we have data - continue receiving
                            self.logger.info("⏳  Handshake incomplete in buffer, continuing to receive")
                            self.receiveHandshakeChunk(for: connectionId, context: context)
                            return
                        }
                    }
                }
                // No data and not complete - continue receiving
                self.receiveHandshakeChunk(for: connectionId, context: context)
            }
        }
    }

    private func processHandshakeBuffer(for connectionId: UUID, context: ConnectionContext) -> Bool {
        logger.info("🔍  processHandshakeBuffer: Checking for handshake delimiter")
        let bufferSnapshot = context.snapshotBuffer()
        logger.info("🔍  processHandshakeBuffer: Buffer size: \(bufferSnapshot.count) bytes")
        if let headerString = String(data: bufferSnapshot.prefix(min(200, bufferSnapshot.count)), encoding: .utf8) {
            logger.info("🔍  processHandshakeBuffer: First 200 chars: \(headerString)")
        }
        
        guard let headerData = context.consumeHeader(upTo: handshakeDelimiter) else {
            logger.info("⏳  processHandshakeBuffer: Handshake delimiter not found yet, waiting for more data")
            return false
        }
        guard let request = String(data: headerData, encoding: .utf8) else {
            sendHTTPError(status: "400 Bad Request", connectionId: connectionId, context: context)
            return true
        }
        let lines = request.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard
            let requestLine = lines.first,
            requestLine.hasPrefix("GET")
        else {
            logger.error("❌ Invalid request line: \(lines.first ?? "none")")
            sendHTTPError(status: "400 Bad Request", connectionId: connectionId, context: context)
            return true
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        logger.info("🔍  processHandshakeBuffer: Parsed \(headers.count) headers")
        guard
            headers["upgrade"]?.lowercased().contains("websocket") == true,
            headers["connection"]?.lowercased().contains("upgrade") == true,
            let key = headers["sec-websocket-key"]
        else {
            logger.info("❌ [LanWebSocketServer] processHandshakeBuffer: Missing required headers. Upgrade: \(headers["upgrade"] ?? "nil"), Connection: \(headers["connection"] ?? "nil"), Key: \(headers["sec-websocket-key"] != nil ? "present" : "missing")")
            sendHTTPError(status: "400 Bad Request", connectionId: connectionId, context: context)
            return true
        }

        // Capture device metadata from headers as early as possible so routing and status work
        if let deviceIdHeader = headers["x-device-id"], !deviceIdHeader.isEmpty {
            updateConnectionMetadata(connectionId: connectionId, deviceId: deviceIdHeader)
            logger.info("🔍  Captured deviceId from headers: \(deviceIdHeader)")
        }

        logger.info("✅  processHandshakeBuffer: All headers valid, sending handshake response")
        let response = handshakeResponse(for: key)
        logger.info("📤 [LanWebSocketServer] Sending HTTP 101 response (\(response.count) bytes) for connection \(connectionId.uuidString.prefix(8))")
        if let responseString = String(data: response, encoding: .utf8) {
            logger.info("📤 [LanWebSocketServer] Response content: \(responseString)")
        }
        
        // Use .contentProcessed to ensure the response is fully sent before starting frame reception
        // Mark as upgraded BEFORE sending so connection is ready to receive frames immediately
        context.upgraded = true
        logger.info("✅ [LanWebSocketServer] Marking connection as upgraded before sending 101 response")
        
        context.connection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            Task { @MainActor [self] in
                guard let context = self.connections[connectionId] else {
                    self.logger.warning("⚠️ [LanWebSocketServer] Connection context not found after handshake send")
                    return
                }
                if let error {
                    #if canImport(os)
                    self.logger.error("Handshake send error: \(error.localizedDescription)")
                    #endif
                    self.logger.error("❌ [LanWebSocketServer] Handshake send error: \(error.localizedDescription)")
                    self.closeConnection(connectionId)
                    return
                }
                // Get device ID from metadata for logging
                let deviceId = self.connectionMetadata[connectionId]?.deviceId ?? "unknown"
                #if canImport(os)
                self.logger.info("✅ CLIPBOARD HANDSHAKE COMPLETE: WebSocket upgraded for \(connectionId.uuidString.prefix(8))")
                #endif
                self.logger.info("✅ [LanWebSocketServer] HTTP 101 response sent successfully, connection upgraded")
                self.logger.info("🔗 [LanWebSocketServer] Connection state after handshake: \(context.connection.state)")
                self.logger.info("📱 [LanWebSocketServer] Client connected: deviceId=\(deviceId), connectionId=\(connectionId.uuidString.prefix(8))")
                
                // Notify delegate that connection is accepted
                self.delegate?.server(self, didAcceptConnection: connectionId)
                
                // Process any frames that might already be in the buffer
                self.processFrameBuffer(for: connectionId, context: context)
                
                // Start receiving WebSocket frames immediately after handshake
                // .contentProcessed ensures the HTTP 101 response is fully sent before this callback runs
                // Starting frame reception immediately ensures OkHttp can read frames as soon as it's ready
                self.logger.info("📡 [LanWebSocketServer] Starting receiveFrameChunk for connection \(connectionId.uuidString.prefix(8))")
                self.receiveFrameChunk(for: connectionId, context: context)
            }
        })
        return true
    }

    private func receiveFrameChunk(for connectionId: UUID, context: ConnectionContext) {
        #if canImport(os)
        logger.debug("📡 CLIPBOARD RECEIVE: Setting up receive callback for connection \(connectionId.uuidString.prefix(8))")
        #endif
        logger.info("📡  CLIPBOARD RECEIVE: Setting up receive callback for \(connectionId.uuidString.prefix(8))")
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self = self else {
                    NSLog("⚠️  Self is nil in receive callback")
                    return
                }
            Task { @MainActor [self] in
                guard let context = self.connections[connectionId] else {
                    self.logger.info("⚠️  Connection context not found for \(connectionId.uuidString.prefix(8))")
                    return
                }
                if let error = error {
                    self.logger.error("❌ [LanWebSocketServer] Frame receive error: \(error.localizedDescription)")
                    #if canImport(os)
                    self.logger.error("Frame receive error: \(error.localizedDescription)")
                    #endif
                    self.closeConnection(connectionId)
                    return
                }
                if let data, !data.isEmpty {
                    #if canImport(os)
                    self.logger.info("📥 FRAME RECEIVED: \(data.count) bytes from connection \(connectionId.uuidString.prefix(8))")
                    #endif
                    self.logger.info("📥 [LanWebSocketServer] FRAME RECEIVED: \(data.count) bytes from \(connectionId.uuidString.prefix(8))")
                    self.logger.info("📥 [LanWebSocketServer] Appending \(data.count) bytes to buffer for \(connectionId.uuidString.prefix(8))")
                    context.appendToBuffer(data)
                    self.logger.info("📦 [LanWebSocketServer] Calling processFrameBuffer for \(connectionId.uuidString.prefix(8))")
                    self.processFrameBuffer(for: connectionId, context: context)
                    // Continue receiving only if connection still exists (might have been closed by close frame)
                    guard self.connections[connectionId] != nil else {
                        self.logger.info("⏸️ [LanWebSocketServer] Connection closed, stopping receive loop")
                        return
                    }
                    // Continue receiving even if isComplete is true (isComplete just means this receive operation finished)
                    self.receiveFrameChunk(for: connectionId, context: context)
                } else if isComplete {
                    // Connection was closed by peer (no data and isComplete means EOF)
                    // But check if we have pending data in buffer first
                    let remainingBuffer = context.snapshotBuffer()
                    if remainingBuffer.isEmpty {
                        // Check connection state - if it's still ready, this might be a false EOF
                        // (e.g., OkHttp hasn't started reading yet after handshake)
                        let connectionState = context.connection.state
                        if connectionState == .ready {
                            // Connection is still ready, this might be a false EOF right after handshake
                            // Continue receiving - OkHttp might not have started reading frames yet
                            self.logger.info("⏳ [LanWebSocketServer] EOF received but connection still ready (might be false EOF after handshake), continuing to receive...")
                            self.receiveFrameChunk(for: connectionId, context: context)
                            return
                        }
                        self.logger.info("🔌 [LanWebSocketServer] Connection \(connectionId.uuidString.prefix(8)) closed by peer (EOF - no data, isComplete=true, buffer empty, state=\(connectionState))")
                        #if canImport(os)
                        self.logger.info("Connection \(connectionId.uuidString) closed by peer")
                        #endif
                        self.closeConnection(connectionId)
                        return
                    } else {
                        self.logger.info("🔌 [LanWebSocketServer] Connection EOF received but \(remainingBuffer.count) bytes still in buffer, processing remaining data")
                        // Process remaining buffer data before closing
                        self.processFrameBuffer(for: connectionId, context: context)
                        // Check again if connection still exists and buffer is empty
                        guard self.connections[connectionId] != nil else {
                            return
                        }
                        let finalBuffer = context.snapshotBuffer()
                        if finalBuffer.isEmpty || finalBuffer.count < 2 {
                            self.logger.info("🔌 [LanWebSocketServer] All data processed, closing connection")
                            self.closeConnection(connectionId)
                            return
                        } else {
                            // Still have data, continue receiving
                            self.receiveFrameChunk(for: connectionId, context: context)
                        }
                    }
                } else {
                    // No data yet, but connection still open - continue receiving
                    self.logger.info("⏳ [LanWebSocketServer] No data yet, continuing to wait for frames...")
                    self.receiveFrameChunk(for: connectionId, context: context)
                }
            }
        }
    }

    private func processFrameBuffer(for connectionId: UUID, context: ConnectionContext) {
        logger.info("🔍 [LanWebSocketServer] processFrameBuffer called: connectionId=\(connectionId.uuidString.prefix(8)), upgraded=\(context.upgraded)")
        guard context.upgraded else {
            logger.info("⏸️ [LanWebSocketServer] Frame processing skipped - connection not upgraded")
            #if canImport(os)
            logger.debug("⏸️ Frame processing skipped - connection not upgraded: \(connectionId.uuidString)")
            #endif
            return
        }
        // Check if connection still exists (might have been closed)
        guard connections[connectionId] != nil else {
            logger.info("⏸️ [LanWebSocketServer] Frame processing skipped - connection already closed")
            return
        }
        while true {
            // Check if connection still exists before each iteration (might be closed by close frame)
            guard connections[connectionId] != nil else {
                logger.info("⏸️ [LanWebSocketServer] Frame processing stopped - connection closed")
                return
            }
            // Work on a snapshot to avoid races with concurrent appends
            let bufferSnapshot = context.snapshotBuffer()
            logger.info("🔍 [LanWebSocketServer] Buffer snapshot size: \(bufferSnapshot.count) bytes")
            guard bufferSnapshot.count >= 2 else {
                logger.info("⏸️ [LanWebSocketServer] Frame processing paused - buffer too small (\(bufferSnapshot.count) bytes)")
                #if canImport(os)
                logger.debug("⏸️ Frame processing paused - buffer too small (\(bufferSnapshot.count) bytes)")
                #endif
                return
            }
            
            var headerBytes = [UInt8](repeating: 0, count: 2)
            bufferSnapshot.copyBytes(to: &headerBytes, count: 2)
            let firstByte = headerBytes[0]
            let secondByte = headerBytes[1]
            let isFinal = (firstByte & 0x80) != 0
            let opcode = firstByte & 0x0F
            let isMasked = (secondByte & 0x80) != 0
            var offset = 2
            var payloadLength = Int(secondByte & 0x7F)
            
            logger.info("🔍 [LanWebSocketServer] Frame header: firstByte=0x\(String(firstByte, radix: 16)), secondByte=0x\(String(secondByte, radix: 16)), isFinal=\(isFinal), opcode=\(opcode), isMasked=\(isMasked), initialPayloadLength=\(payloadLength)")
            
            if payloadLength == 126 {
                guard bufferSnapshot.count >= offset + 2 else {
                    logger.info("⏸️ [LanWebSocketServer] Need 2 more bytes for extended length (have \(bufferSnapshot.count), need \(offset + 2))")
                    return
                }
                let lengthBytes = bufferSnapshot.subdata(in: offset..<offset + 2)
                payloadLength = Int(readUInt16(from: lengthBytes, offset: 0))
                offset += 2
                logger.info("🔍 [LanWebSocketServer] Extended length (126): payloadLength=\(payloadLength)")
            } else if payloadLength == 127 {
                guard bufferSnapshot.count >= offset + 8 else {
                    logger.info("⏸️ [LanWebSocketServer] Need 8 more bytes for extended length (have \(bufferSnapshot.count), need \(offset + 8))")
                    return
                }
                let lengthBytes = bufferSnapshot.subdata(in: offset..<offset + 8)
                payloadLength = Int(readUInt64(from: lengthBytes, offset: 0))
                offset += 8
                logger.info("🔍 [LanWebSocketServer] Extended length (127): payloadLength=\(payloadLength)")
            }
            
            let maskLength = isMasked ? 4 : 0
            let requiredLength = offset + maskLength + payloadLength
            logger.info("🔍 [LanWebSocketServer] Required length: offset=\(offset), maskLength=\(maskLength), payloadLength=\(payloadLength), required=\(requiredLength), buffer=\(bufferSnapshot.count)")
            guard bufferSnapshot.count >= requiredLength else {
                logger.info("⏸️ [LanWebSocketServer] Need \(requiredLength - bufferSnapshot.count) more bytes (have \(bufferSnapshot.count), need \(requiredLength))")
                return
            }
            
            // Extract all needed data atomically before processing
            let frameData = bufferSnapshot.subdata(in: 0..<requiredLength)
            var payload = frameData.subdata(in: offset + maskLength..<requiredLength)
            
            if isMasked {
                let maskStart = offset
                let maskBytes = Array(frameData[maskStart..<maskStart + 4])
                unmask(&payload, with: maskBytes)
            }
            
            // Remove processed frame from buffer
            context.dropPrefix(requiredLength)
            logger.info("📦 [LanWebSocketServer] FRAME PROCESSING: opcode=\(opcode), payload=\(payload.count) bytes, masked=\(isMasked), isFinal=\(isFinal), connection=\(connectionId.uuidString.prefix(8))")
            #if canImport(os)
            logger.info("📦 FRAME PROCESSING: opcode=\(opcode), payload=\(payload.count) bytes, masked=\(isMasked), connection=\(connectionId.uuidString.prefix(8))")
            #endif
            
            // Call handleFrame (doesn't throw, so no error handling needed)
            logger.info("🔵  About to call handleFrame")
            handleFrame(opcode: opcode, isFinal: isFinal, payload: payload, connectionId: connectionId, context: context)
            logger.info("🔵  Returned from handleFrame")
            
            // If this was a close frame, mark as pending close but continue processing remaining data
            if opcode == 0x8 {
                logger.info("🔌 [LanWebSocketServer] Close frame received, marking connection for close after data is depleted")
                context.pendingClose = true
                // Don't return - continue processing any remaining frames in the buffer
            }
            
            // After processing frame, check if we should close (pending close and buffer is empty)
            if context.pendingClose {
                let remainingBuffer = context.snapshotBuffer()
                if remainingBuffer.count < 2 {
                    // Buffer is empty or too small for another frame - safe to close
                    logger.info("🔌 [LanWebSocketServer] All data depleted, closing connection as requested by peer")
                    closeConnection(connectionId)
                    return
                } else {
                    logger.info("🔌 [LanWebSocketServer] Close frame received but \(remainingBuffer.count) bytes still in buffer, continuing to process")
                    // Continue processing remaining frames
                }
            }
        }
    }

    private func handleFrame(opcode: UInt8, isFinal: Bool, payload: Data, connectionId: UUID, context: ConnectionContext) {
        logger.info("🎯 [LanWebSocketServer] handleFrame called: opcode=\(opcode), isFinal=\(isFinal), payload=\(payload.count) bytes")
        guard isFinal else {
            logger.warning("⚠️ [LanWebSocketServer] Fragmented frames are not supported")
            #if canImport(os)
            logger.warning("⚠️ Fragmented frames are not supported")
            #endif
            return
        }
        switch opcode {
        case 0x1, 0x2:
            // Skip empty payloads (could be ping/pong or malformed frames)
            guard !payload.isEmpty else {
                logger.info("⏭️ [LanWebSocketServer] Skipping empty data frame from \(connectionId.uuidString.prefix(8))")
                #if canImport(os)
                logger.info("⏭️ Skipping empty data frame")
                #endif
                return
            }
            // Skip frames that are too small to contain a valid frame header (4 bytes minimum for TransportFrameCodec)
            guard payload.count >= 4 else {
                logger.info("⏭️ [LanWebSocketServer] Skipping truncated frame from \(connectionId.uuidString.prefix(8)) (\(payload.count) bytes < 4)")
                #if canImport(os)
                logger.info("⏭️ Skipping truncated frame (\(payload.count) bytes < 4)")
                #endif
                return
            }
            logger.info("📨 [LanWebSocketServer] FRAME HANDLED: data frame opcode=\(opcode), \(payload.count) bytes")
            #if canImport(os)
            logger.info("📨 FRAME HANDLED: data frame opcode=\(opcode), \(payload.count) bytes from \(connectionId.uuidString.prefix(8))")
            #endif
            handleReceivedData(payload, from: connectionId)
        case 0x8:
            logger.info("🔌  Close frame received from \(connectionId.uuidString)")
            // Don't close immediately - mark as pending close and let processFrameBuffer handle it
            // after all data frames are processed
            if let context = connections[connectionId] {
                context.pendingClose = true
                logger.info("🔌 [LanWebSocketServer] Marked connection for close, will close after data is depleted")
            } else {
                // Connection already closed, nothing to do
                logger.info("🔌 [LanWebSocketServer] Close frame received but connection already closed")
            }
        case 0x9:
            sendFrame(payload: payload, opcode: 0xA, context: context) { _ in }
        case 0xA:
            // Pong - ignore
            break
        default:
            logger.info("⚠️  Unsupported opcode \(opcode)")
        }
    }

    private func handshakeResponse(for clientKey: String) -> Data {
        let acceptSource = clientKey + websocketGUID
        let digest = Insecure.SHA1.hash(data: Data(acceptSource.utf8))
        let acceptValue = Data(digest).base64EncodedString()
        let responseLines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptValue)",
            "",
            ""
        ]
        return Data(responseLines.joined(separator: "\r\n").utf8)
    }

    private func sendHTTPError(status: String, connectionId: UUID, context: ConnectionContext) {
        let response = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        context.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [self] in
                self.closeConnection(connectionId)
            }
        })
    }

    private func readUInt16(from data: Data, offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        let high = UInt16(data[offset]) << 8
        let low = UInt16(data[offset + 1])
        return high | low
    }

    private func readUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset + 7 < data.count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }

    private func unmask(_ payload: inout Data, with mask: [UInt8]) {
        guard mask.count == 4 else { return }
        let count = payload.count
        payload.withUnsafeMutableBytes { bytes in
            guard let buffer = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0..<count {
                buffer[index] ^= mask[index % 4]
            }
        }
    }
    
    private func handleReceivedData(_ data: Data, from connectionId: UUID) {
        logger.info("📨 [LanWebSocketServer] CLIPBOARD DATA RECEIVED: \(data.count) bytes from \(connectionId.uuidString.prefix(8))")
        #if canImport(os)
        logger.info("📨 CLIPBOARD DATA RECEIVED: \(data.count) bytes from connection \(connectionId.uuidString.prefix(8))")
        #endif
        
        // Skip empty data (should have been caught in handleFrame, but double-check here)
        guard !data.isEmpty else {
            logger.info("⏭️ [LanWebSocketServer] Skipping empty data in handleReceivedData from \(connectionId.uuidString.prefix(8))")
            return
        }
        
        // Skip frames that are too small to contain a valid frame header (4 bytes minimum)
        guard data.count >= 4 else {
            logger.info("⏭️ [LanWebSocketServer] Skipping truncated frame in handleReceivedData from \(connectionId.uuidString.prefix(8)) (\(data.count) bytes < 4)")
            return
        }
        
        // Simple test log to verify execution continues
        logger.info("🔍 TEST: After CLIPBOARD DATA RECEIVED log")
        
        // Decode the frame-encoded payload (Android sends: 4-byte length + JSON)
        // Try to decode as TransportFrameCodec frame first (for clipboard messages)
        logger.info("🔍  Attempting to decode frame: \(data.count) bytes")
        do {
            let envelope = try frameCodec.decode(data)
            #if canImport(os)
            logger.info("✅ CLIPBOARD FRAME DECODED: envelope type=\(envelope.type.rawValue)")
            #endif
            logger.info("✅  CLIPBOARD FRAME DECODED: type=\(envelope.type.rawValue)")
            
            // Simple test log
            logger.info("🔍 TEST2: After CLIPBOARD FRAME DECODED")
            
            // Handle based on envelope type
            logger.info("🔍  Switching on envelope type")
            switch envelope.type {
            case .error:
                // Error messages from server - log and ignore
                logger.warning("⚠️ [LanWebSocketServer] Received error message from server (id: \(envelope.id))")
                return
            case .clipboard:
                logger.info("✅  Case .clipboard matched")
                
                // Check target field - only process if target is nil/empty OR matches local device ID
                // Compare case-insensitively since UUIDs can be in different cases
                let target = envelope.payload.target
                if let target = target, !target.isEmpty {
                    if let localId = localDeviceId, target.lowercased() != localId.lowercased() {
                        logger.info("⏭️ [LanWebSocketServer] Skipping message - target (\(target)) does not match local device ID (\(localId))")
                        #if canImport(os)
                        logger.info("⏭️ Skipping message - target (\(target)) does not match local device ID (\(localId))")
                        #endif
                        return  // Skip this message - it's not for us
                    }
                }
                
                // Forward the original frame-encoded data to the delegate
                // (it will decode it again in IncomingClipboardHandler)
                #if canImport(os)
                logger.info("✅ CLIPBOARD MESSAGE RECEIVED: forwarding to delegate, \(data.count) bytes")
                #endif
                logger.info("✅  CLIPBOARD MESSAGE RECEIVED: \(data.count) bytes, forwarding to delegate")
                logger.info("🔍  About to call delegate?.server()")
                if let delegate = delegate {
                    logger.info("✅  Delegate exists: \(type(of: delegate))")
                    delegate.server(self, didReceiveClipboardData: data, from: connectionId)
                    logger.info("✅  delegate.server() called")
                } else {
                    logger.info("❌  Delegate is nil!")
                }
                return
            case .control:
                #if canImport(os)
                logger.info("📋 CLIPBOARD CONTROL MESSAGE: ignoring for now")
                #endif
                logger.info("📋  CLIPBOARD CONTROL MESSAGE: ignoring")
                return
            }
        } catch let decodingError as DecodingError {
            // Detailed decoding error logging
            logger.error("⚠️ [LanWebSocketServer] CLIPBOARD FRAME DECODE FAILED: DecodingError")
            #if canImport(os)
            logger.error("⚠️ CLIPBOARD FRAME DECODE FAILED: DecodingError")
            switch decodingError {
            case .typeMismatch(let type, let context):
                logger.error("   Type mismatch: expected \(String(describing: type)) at path: \(context.codingPath.map { $0.stringValue })")
            case .keyNotFound(let key, let context):
                logger.error("   Key not found: \(key.stringValue) at path: \(context.codingPath.map { $0.stringValue })")
            case .valueNotFound(let type, let context):
                logger.error("   Value not found: \(String(describing: type)) at path: \(context.codingPath.map { $0.stringValue })")
            case .dataCorrupted(let context):
                logger.error("   Data corrupted: \(context.debugDescription) at path: \(context.codingPath.map { $0.stringValue })")
            @unknown default:
                logger.error("   Unknown decoding error")
            }
            #endif
            logger.info("⚠️  CLIPBOARD FRAME DECODE FAILED: DecodingError")
            switch decodingError {
            case .typeMismatch(let type, let context):
                logger.info("   Type mismatch: expected \(String(describing: type)) at path: \(context.codingPath.map { $0.stringValue })")
            case .keyNotFound(let key, let context):
                logger.info("   Key not found: \(key.stringValue) at path: \(context.codingPath.map { $0.stringValue })")
            case .valueNotFound(let type, let context):
                logger.info("   Value not found: \(String(describing: type)) at path: \(context.codingPath.map { $0.stringValue })")
            case .dataCorrupted(let context):
                logger.info("   Data corrupted: \(context.debugDescription) at path: \(context.codingPath.map { $0.stringValue })")
            @unknown default:
                logger.info("   Unknown decoding error")
            }
            logger.info("   Data size: \(data.count) bytes")
            if data.count >= 4 {
                let lengthBytes = data.prefix(4)
                let lengthValue = lengthBytes.withUnsafeBytes { buffer -> UInt32 in
                    buffer.load(as: UInt32.self)
                }
                let length = Int(UInt32(bigEndian: lengthValue))
                logger.info("   First 4 bytes as length: \(length) (data has \(data.count) bytes)")
                if data.count > 4 && length > 0 && length <= data.count - 4 {
                    let jsonData = data.subdata(in: 4..<(4 + length))
                    if let jsonString = String(data: jsonData, encoding: .utf8) {
                        logger.info("   Full JSON: \(jsonString)")
                    }
                }
            }
        } catch {
            // Other errors (including TransportFrameError for non-frame messages like pairing)
            logger.error("⚠️ [LanWebSocketServer] CLIPBOARD FRAME DECODE FAILED: \(error.localizedDescription), type: \(String(describing: type(of: error)))")
            #if canImport(os)
            logger.error("⚠️ CLIPBOARD FRAME DECODE FAILED: \(error.localizedDescription)")
            logger.error("   Error type: \(String(describing: type(of: error)))")
            #endif
            // Continue to fallback detection - this is expected for pairing messages which are raw JSON
        }
        
        // Fall back to direct JSON parsing for pairing messages (raw JSON, not wrapped in TransportFrame)
        logger.info("🔍  Falling back to message type detection...")
        let messageType = detectMessageType(data)
        
        #if canImport(os)
        logger.info("📋 CLIPBOARD MESSAGE TYPE: \(String(describing: messageType))")
        #endif
        logger.info("📋  CLIPBOARD MESSAGE TYPE: \(String(describing: messageType))")
        
        switch messageType {
        case .pairing:
            logger.info("✅  Switch case .pairing matched!")
            // Log JSON before attempting decode
            #if canImport(os)
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.info("🔍 CLIPBOARD PAIRING MESSAGE: \(jsonString.prefix(200))")
            }
            #endif
            logger.info("🔍  CLIPBOARD PAIRING MESSAGE detected")
            logger.info("🔍  About to call handlePairingMessage...")
            do {
                try handlePairingMessage(data, from: connectionId)
                logger.info("✅  handlePairingMessage completed successfully")
            } catch let decodingError as DecodingError {
                #if canImport(os)
                logger.error("❌ Decoding error: \(decodingError.localizedDescription)")
                switch decodingError {
                case .dataCorrupted(let context):
                    logger.error("   Data corrupted: \(context.debugDescription)")
                    logger.error("   Coding path: \(context.codingPath.map { $0.stringValue })")
                case .keyNotFound(let key, let context):
                    logger.error("   Key not found: \(key.stringValue)")
                    logger.error("   Coding path: \(context.codingPath.map { $0.stringValue })")
                case .typeMismatch(let type, let context):
                    logger.error("   Type mismatch: expected \(type), at path: \(context.codingPath.map { $0.stringValue })")
                case .valueNotFound(let type, let context):
                    logger.error("   Value not found: \(type), at path: \(context.codingPath.map { $0.stringValue })")
                @unknown default:
                    logger.error("   Unknown decoding error")
                }
                // Log the raw JSON for debugging
                if let jsonString = String(data: data, encoding: .utf8) {
                    logger.error("   Raw JSON: \(jsonString)")
                }
                #endif
                // Log error but don't crash - return instead
                logger.info("❌ ERROR: Pairing message decoding failed: \(decodingError)")
                if let jsonString = String(data: data, encoding: .utf8) {
                    logger.info("   Raw JSON: \(jsonString)")
                }
                // Don't crash - just return and log the error
                return
            } catch {
                #if canImport(os)
                logger.error("❌ Failed to handle pairing message: \(error.localizedDescription)")
                logger.error("   Error type: \(String(describing: type(of: error)))")
                if let jsonString = String(data: data, encoding: .utf8) {
                    logger.error("   Raw JSON: \(jsonString)")
                }
                #endif
                logger.info("❌ ERROR: Pairing message handling failed: \(error)")
                if let jsonString = String(data: data, encoding: .utf8) {
                    logger.info("   Raw JSON: \(jsonString)")
                }
                // Don't crash - just return and log the error
                return
            }
        case .clipboard:
            // This case should not be reached if frame decoding succeeded above
            // But keep it as fallback for non-frame-encoded clipboard messages
            #if canImport(os)
            logger.info("✅ CLIPBOARD MESSAGE RECEIVED (fallback): forwarding to delegate, \(data.count) bytes")
            #endif
            logger.info("✅  CLIPBOARD MESSAGE RECEIVED (fallback): \(data.count) bytes, forwarding to delegate")
            delegate?.server(self, didReceiveClipboardData: data, from: connectionId)
        case .unknown:
            #if canImport(os)
            logger.warning("⚠️ CLIPBOARD UNKNOWN MESSAGE TYPE from \(connectionId.uuidString.prefix(8)), \(data.count) bytes")
            #endif
            logger.info("⚠️  CLIPBOARD UNKNOWN MESSAGE TYPE: \(data.count) bytes")
        }
    }
    
    private func detectMessageType(_ data: Data) -> WebSocketMessageType {
        // Try to decode as JSON to peek at the structure
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            #if canImport(os)
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.error("⚠️ Failed to parse JSON: \(jsonString)")
            }
            #endif
            logger.info("⚠️  Failed to parse JSON in detectMessageType")
            return .unknown
        }
        
        #if canImport(os)
        // Log the raw JSON for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            logger.info("📥 Received JSON: \(jsonString)")
        }
        logger.info("📋 JSON keys: \(Array(json.keys).sorted().joined(separator: ", "))")
        #endif
        logger.info("📋 [LanWebSocketServer] JSON keys: \(Array(json.keys).sorted().joined(separator: ", "))")
        
        // Pairing messages have initiator_device_id and initiator_pub_key
        // Check for pairing-specific fields
        let hasInitiatorFields = json["initiator_device_id"] != nil && json["initiator_pub_key"] != nil
        let hasChallengeId = json["challenge_id"] != nil
        
        if hasInitiatorFields {
            #if canImport(os)
            logger.info("✅ Detected pairing message (has initiator_device_id and initiator_pub_key)")
            #endif
            logger.info("✅  Detected pairing message (has initiator_device_id and initiator_pub_key)")
            return .pairing
        }
        
        // Also check for challenge_id if present
        if hasChallengeId {
            #if canImport(os)
            logger.info("✅ Detected pairing message (has challenge_id)")
            #endif
            logger.info("✅  Detected pairing message (has challenge_id)")
            return .pairing
        }
        
        // Clipboard messages have type field
        if json["type"] != nil {
            return .clipboard
        }
        
        #if canImport(os)
        logger.warning("⚠️ Unknown message type - no pairing or clipboard fields detected")
        #endif
        return .unknown
    }
    
    private func handlePairingMessage(_ data: Data, from connectionId: UUID) throws {
        logger.info("🔵  handlePairingMessage called: \(data.count) bytes from \(connectionId.uuidString.prefix(8))")
        #if canImport(os)
        logger.info("📥 Received pairing message: \(data.count) bytes from \(connectionId.uuidString)")
        if let jsonString = String(data: data, encoding: .utf8) {
            logger.info("📥 Raw JSON (full): \(jsonString)")
            // Also try to parse as dictionary to see what keys are present
            if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                logger.info("📥 JSON keys found: \(Array(jsonDict.keys).sorted().joined(separator: ", "))")
                for (key, value) in jsonDict {
                    if let strValue = value as? String {
                        logger.info("📥   \(key): \(strValue.prefix(50))...")
                    } else {
                        logger.info("📥   \(key): \(type(of: value))")
                    }
                }
            }
        }
        #endif
        
        let decoder = JSONDecoder()
        // Don't use convertFromSnakeCase - CodingKeys already specify snake_case names
        decoder.dateDecodingStrategy = .iso8601
        
        // Let decode errors propagate
        let challenge = try decoder.decode(PairingChallengeMessage.self, from: data)
        #if canImport(os)
        logger.info("✅ Decoded pairing challenge from device: \(challenge.initiatorDeviceName)")
        #endif
        logger.info("🔵  About to call delegate?.server(didReceivePairingChallenge:)")
        if let delegate = delegate {
            logger.info("✅  Delegate exists, calling didReceivePairingChallenge")
            delegate.server(self, didReceivePairingChallenge: challenge, from: connectionId)
            logger.info("✅  delegate.server(didReceivePairingChallenge:) called")
        } else {
            logger.info("❌  Delegate is nil! Cannot process pairing challenge")
        }
    }
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .setup:
            logger.info("🟡 [LanWebSocketServer] Listener setting up")
        case .ready:
            #if canImport(os)
            logger.info("✅ WebSocket server ready and listening on all interfaces")
            #endif
            logger.info("✅ [LanWebSocketServer] Server is ready and listening on all interfaces (0.0.0.0)")
            
            // Log network interfaces for debugging
            logNetworkInterfaces()
        case .failed(let error):
            #if canImport(os)
            logger.error("❌ WebSocket server failed: \(error.localizedDescription)")
            #endif
            logger.error("❌ [LanWebSocketServer] Server failed: \(error.localizedDescription)")
        case .cancelled:
            #if canImport(os)
            logger.info("🛑 WebSocket server cancelled")
            #endif
            logger.info("🛑 [LanWebSocketServer] Server cancelled")
        case .waiting(let error):
            logger.warning("⏳ [LanWebSocketServer] Server waiting: \(error.localizedDescription)")
        @unknown default:
            #if canImport(os)
            logger.debug("🟡 WebSocket server state: \(String(describing: state))")
            #endif
            logger.info("🟡 [LanWebSocketServer] Server state: \(String(describing: state))")
        }
    }
    
    private func logNetworkInterfaces() {
        // Log available network interfaces for debugging connection issues
        var interfaces: [String] = []
        var allInterfaces: [String] = [] // Track all interfaces for debugging
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            logger.warning("⚠️ [LanWebSocketServer] Failed to get network interfaces: errno=\(errno)")
            return
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee else { continue }
            let flags = Int32(interface.ifa_flags)
            let name = String(cString: interface.ifa_name)
            
            // Track all interfaces for debugging
            var status = ""
            if (flags & IFF_UP) != 0 { status += "UP " }
            if (flags & IFF_RUNNING) != 0 { status += "RUNNING " }
            if (flags & IFF_LOOPBACK) != 0 { status += "LOOPBACK " }
            allInterfaces.append("\(name): flags=\(flags) (\(status.trimmingCharacters(in: .whitespaces)))")
            
            // Check if interface is up and not loopback
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) && (flags & IFF_LOOPBACK) == 0 {
                if let addr = interface.ifa_addr {
                    let addrFamily = addr.pointee.sa_family
                    if addrFamily == AF_INET {
                        let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        if let addrString = inet_ntoa(sin.sin_addr) {
                            let ip = String(cString: addrString)
                            interfaces.append("\(name): \(ip)")
                        }
                    } else if addrFamily == AF_INET6 {
                        // Also log IPv6 interfaces for completeness
                        var sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                        var addrBuffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        if inet_ntop(AF_INET6, &sin6.sin6_addr, &addrBuffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                            let ip = String(cString: addrBuffer)
                            interfaces.append("\(name): [\(ip)] (IPv6)")
                        }
                    }
                }
            }
        }
        
        if !interfaces.isEmpty {
            logger.info("📡 [LanWebSocketServer] Available network interfaces:")
            for interface in interfaces {
                logger.info("   - \(interface)")
            }
        } else {
            // Log all interfaces for debugging when none are found
            logger.warning("⚠️ [LanWebSocketServer] No active network interfaces found")
            if !allInterfaces.isEmpty {
                logger.info("📡 [LanWebSocketServer] All detected interfaces:")
                for interface in allInterfaces {
                    logger.info("   - \(interface)")
                }
            } else {
                logger.warning("⚠️ [LanWebSocketServer] No network interfaces detected at all (network may be down)")
            }
        }
    }
    
    // Connection state is now handled in handleNewConnection's stateUpdateHandler
    // This method is kept for backward compatibility but may not be called
    
    private func closeConnection(_ id: UUID) {
        let deviceId = connectionMetadata[id]?.deviceId ?? "unknown"
        let wasUpgraded = connections[id]?.upgraded ?? false
        logger.info("🔌 [LanWebSocketServer] closeConnection called: \(id.uuidString.prefix(8)), deviceId=\(deviceId), upgraded=\(wasUpgraded)")
        // Log stack trace to see where closeConnection is being called from
        let stackTrace = Thread.callStackSymbols.prefix(5).joined(separator: " -> ")
        logger.info("🔌 [LanWebSocketServer] closeConnection call stack: \(stackTrace)")
        connections[id]?.connection.cancel()
        connections.removeValue(forKey: id)
        connectionMetadata.removeValue(forKey: id)
        delegate?.server(self, didCloseConnection: id)
        
        #if canImport(os)
        logger.info("Connection closed: \(id.uuidString)")
        #endif
    }
}
