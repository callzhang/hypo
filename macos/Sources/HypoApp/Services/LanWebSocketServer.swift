import Foundation
import Network
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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
    private final class ConnectionContext: @unchecked Sendable {
        let connection: NWConnection
        private var buffer = Data()
        // Protects buffer mutations so concurrent frame appends can't corrupt indices (Issue 7)
        private let bufferLock = NSLock()
        var upgraded = false

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
    
    public func connectionMetadata(for connectionId: UUID) -> ConnectionMetadata? {
        connectionMetadata[connectionId]
    }
    
    public func updateConnectionMetadata(connectionId: UUID, deviceId: String) {
        if var existing = connectionMetadata[connectionId] {
            connectionMetadata[connectionId] = ConnectionMetadata(deviceId: deviceId, connectedAt: existing.connectedAt)
        } else {
            connectionMetadata[connectionId] = ConnectionMetadata(deviceId: deviceId, connectedAt: Date())
        }
    }
    
    #if canImport(os)
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "lan-server")
    #endif
    
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
    
    public init() {}
    
    public func start(port: Int) throws {
        print("🚀 [LanWebSocketServer] Starting WebSocket server on port \(port)")
        #if canImport(os)
        logger.info("Starting WebSocket server on port \(port)")
        #endif
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = false  // Allow connections from LAN
        
        // Enable additional logging
        print("🔧 [LanWebSocketServer] Listener configured for manual WebSocket handling (raw TCP)")
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        } catch {
            #if canImport(os)
            logger.error("Failed to create listener: \(error.localizedDescription)")
            #endif
            throw error
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            print("🔔 [LanWebSocketServer] newConnectionHandler called!")
            print("🔔 [LanWebSocketServer] Connection endpoint: \(connection.currentPath?.localEndpoint ?? connection.endpoint)")
            print("🔔 [LanWebSocketServer] Connection state: \(connection.state)")
            // Don't wrap in Task - handleNewConnection is already @MainActor
            // But we need to ensure we're on the main actor
            DispatchQueue.main.async {
                print("🔔 [LanWebSocketServer] On main queue, calling handleNewConnection...")
                Task { @MainActor in
                    print("🔔 [LanWebSocketServer] Inside Task, calling handleNewConnection...")
                    self?.handleNewConnection(connection)
                }
            }
        }
        
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state)
            }
        }
        
        print("🚀 [LanWebSocketServer] Starting listener on port \(port)...")
        listener?.start(queue: .main)
        print("🚀 [LanWebSocketServer] Listener.start() called, waiting for connections...")
    }
    
    public func stop() {
        #if canImport(os)
        logger.info("Stopping WebSocket server")
        #endif
        
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
        guard let context = connections[connectionId], context.upgraded else {
            throw NSError(domain: "LanWebSocketServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Connection not found"
            ])
        }
        sendFrame(payload: data, opcode: 0x2, context: context) { error in
            if let error {
                #if canImport(os)
                self.logger.error("Send error: \(error.localizedDescription)")
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
        let activeMsg = "🔍 [LanWebSocketServer] activeConnections() called: \(active.count) connections\n"
        print(activeMsg)
        try? activeMsg.appendToFile(path: "/tmp/hypo_debug.log")
        if active.count > 0 {
            for id in active {
                if let metadata = connectionMetadata[id] {
                    let metaMsg = "🔍 [LanWebSocketServer] Connection \(id.uuidString.prefix(8)): deviceId=\(metadata.deviceId ?? "nil"), upgraded=\(connections[id]?.upgraded ?? false)\n"
                    print(metaMsg)
                    try? metaMsg.appendToFile(path: "/tmp/hypo_debug.log")
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
        
        #if canImport(os)
        if let jsonString = String(data: data, encoding: .utf8) {
            logger.info("📤 Sending pairing ACK JSON: \(jsonString)")
        }
        logger.info("📤 Sending pairing ACK (\(data.count) bytes) to connection: \(connectionId.uuidString)")
        #endif
        
        // Send as text frame (not binary) so Android can parse it as JSON string
        guard let context = connections[connectionId], context.upgraded else {
            throw NSError(domain: "LanWebSocketServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Connection not found"
            ])
        }
        sendFrame(payload: data, opcode: 0x1, context: context) { error in
            if let error {
                #if canImport(os)
                self.logger.error("❌ ACK send error: \(error.localizedDescription)")
                #endif
            } else {
                #if canImport(os)
                self.logger.info("✅ Pairing ACK sent successfully")
                #endif
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
        print("🔌 [LanWebSocketServer] handleNewConnection called!")
        let id = UUID()
        let context = ConnectionContext(connection: connection)
        connections[id] = context
        connectionMetadata[id] = ConnectionMetadata(deviceId: nil, connectedAt: Date())
        
        #if canImport(os)
        logger.info("🔌 New WebSocket connection accepted: \(id.uuidString)")
        #endif
        print("🔌 [LanWebSocketServer] New connection: \(id.uuidString)")
        print("🔌 [LanWebSocketServer] Total active connections: \(connections.count)")
        print("🔌 [LanWebSocketServer] Initial connection state: \(String(describing: connection.state))")
        try? "🔌 [LanWebSocketServer] New connection: \(id.uuidString), initial state: \(String(describing: connection.state))\n".appendToFile(path: "/tmp/hypo_debug.log")
        
        // Check initial state - connection might already be ready
        if case .ready = connection.state {
            print("✅ [LanWebSocketServer] Connection already ready, starting handshake immediately")
            try? "✅ [LanWebSocketServer] Connection already ready, starting handshake\n".appendToFile(path: "/tmp/hypo_debug.log")
            beginHandshake(for: id)
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else {
                    print("⚠️ [LanWebSocketServer] Self is nil in stateUpdateHandler")
                    return
                }
                print("🔄 [LanWebSocketServer] Connection state changed for \(id.uuidString.prefix(8)): \(String(describing: state))")
                try? "🔄 [LanWebSocketServer] Connection state changed: \(String(describing: state))\n".appendToFile(path: "/tmp/hypo_debug.log")
                switch state {
                case .ready:
                    #if canImport(os)
                    self.logger.info("✅ Connection ready: \(id.uuidString)")
                    #endif
                    print("✅ [LanWebSocketServer] Connection ready: \(id.uuidString) - performing manual WebSocket handshake")
                    try? "✅ [LanWebSocketServer] Connection ready: \(id.uuidString)\n".appendToFile(path: "/tmp/hypo_debug.log")
                    self.beginHandshake(for: id)
                case .failed(let error):
                    #if canImport(os)
                    self.logger.error("Connection failed: \(error.localizedDescription)")
                    #endif
                    print("❌ [LanWebSocketServer] Connection failed: \(error.localizedDescription)")
                    self.closeConnection(id)
                case .cancelled:
                    print("🔌 [LanWebSocketServer] Connection cancelled: \(id.uuidString)")
                    self.closeConnection(id)
                case .waiting(let error):
                    print("⏳ [LanWebSocketServer] Connection waiting: \(id.uuidString), error: \(error.localizedDescription)")
                default:
                    print("🟡 [LanWebSocketServer] Connection state: \(String(describing: state)) for \(id.uuidString)")
                    break
                }
            }
        }
        
        print("🔌 [LanWebSocketServer] Calling connection.start() for \(id.uuidString)")
        connection.start(queue: .main)
    }

    private func beginHandshake(for connectionId: UUID) {
        print("🤝 [LanWebSocketServer] beginHandshake called for \(connectionId.uuidString.prefix(8))")
        try? "🤝 [LanWebSocketServer] beginHandshake called for \(connectionId.uuidString.prefix(8))\n".appendToFile(path: "/tmp/hypo_debug.log")
        guard let context = connections[connectionId] else {
            print("⚠️ [LanWebSocketServer] No context found for connection \(connectionId.uuidString.prefix(8))")
            return
        }
        receiveHandshakeChunk(for: connectionId, context: context)
    }

    private func receiveHandshakeChunk(for connectionId: UUID, context: ConnectionContext) {
        print("📥 [LanWebSocketServer] receiveHandshakeChunk: Setting up receive callback for \(connectionId.uuidString.prefix(8))")
        try? "📥 [LanWebSocketServer] receiveHandshakeChunk: Setting up receive callback\n".appendToFile(path: "/tmp/hypo_debug.log")
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                guard let context = self.connections[connectionId] else { return }
                if let error = error {
                    #if canImport(os)
                    self.logger.error("Handshake receive error: \(error.localizedDescription)")
                    #endif
                    print("❌ [LanWebSocketServer] Handshake receive error: \(error.localizedDescription)")
                    self.closeConnection(connectionId)
                    return
                }
                if let data, !data.isEmpty {
                    print("📥 [LanWebSocketServer] Handshake data received: \(data.count) bytes")
                    try? "📥 [LanWebSocketServer] Handshake data received: \(data.count) bytes\n".appendToFile(path: "/tmp/hypo_debug.log")
                    context.appendToBuffer(data)
                    print("📥 [LanWebSocketServer] Data appended to buffer, calling processHandshakeBuffer")
                    let processed = self.processHandshakeBuffer(for: connectionId, context: context)
                    print("📥 [LanWebSocketServer] processHandshakeBuffer returned: \(processed)")
                    if processed {
                        print("✅ [LanWebSocketServer] Handshake processing complete, stopping receive loop")
                        return
                    } else {
                        print("⏳ [LanWebSocketServer] Handshake processing incomplete, continuing receive loop")
                    }
                }
                if isComplete {
                    print("⚠️ [LanWebSocketServer] Handshake receive completed without data")
                    self.closeConnection(connectionId)
                    return
                }
                self.receiveHandshakeChunk(for: connectionId, context: context)
            }
        }
    }

    private func processHandshakeBuffer(for connectionId: UUID, context: ConnectionContext) -> Bool {
        print("🔍 [LanWebSocketServer] processHandshakeBuffer: Checking for handshake delimiter")
        let bufferSnapshot = context.snapshotBuffer()
        print("🔍 [LanWebSocketServer] processHandshakeBuffer: Buffer size: \(bufferSnapshot.count) bytes")
        if let headerString = String(data: bufferSnapshot.prefix(min(200, bufferSnapshot.count)), encoding: .utf8) {
            print("🔍 [LanWebSocketServer] processHandshakeBuffer: First 200 chars: \(headerString)")
        }
        
        guard let headerData = context.consumeHeader(upTo: handshakeDelimiter) else {
            print("⏳ [LanWebSocketServer] processHandshakeBuffer: Handshake delimiter not found yet, waiting for more data")
            return false
        }
        print("✅ [LanWebSocketServer] processHandshakeBuffer: Handshake delimiter found, header size: \(headerData.count) bytes")
        
        guard let request = String(data: headerData, encoding: .utf8) else {
            print("❌ [LanWebSocketServer] processHandshakeBuffer: Failed to decode header as UTF-8")
            sendHTTPError(status: "400 Bad Request", connectionId: connectionId, context: context)
            return true
        }
        print("✅ [LanWebSocketServer] processHandshakeBuffer: Header decoded, processing request")
        let lines = request.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard
            let requestLine = lines.first,
            requestLine.hasPrefix("GET")
        else {
            print("❌ [LanWebSocketServer] processHandshakeBuffer: Invalid request line: \(lines.first ?? "none")")
            sendHTTPError(status: "400 Bad Request", connectionId: connectionId, context: context)
            return true
        }
        print("✅ [LanWebSocketServer] processHandshakeBuffer: Request line valid: \(requestLine)")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        print("🔍 [LanWebSocketServer] processHandshakeBuffer: Parsed \(headers.count) headers")
        guard
            headers["upgrade"]?.lowercased().contains("websocket") == true,
            headers["connection"]?.lowercased().contains("upgrade") == true,
            let key = headers["sec-websocket-key"]
        else {
            print("❌ [LanWebSocketServer] processHandshakeBuffer: Missing required headers. Upgrade: \(headers["upgrade"] ?? "nil"), Connection: \(headers["connection"] ?? "nil"), Key: \(headers["sec-websocket-key"] != nil ? "present" : "missing")")
            sendHTTPError(status: "400 Bad Request", connectionId: connectionId, context: context)
            return true
        }
        print("✅ [LanWebSocketServer] processHandshakeBuffer: All headers valid, sending handshake response")
        let response = handshakeResponse(for: key)
        context.connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    #if canImport(os)
                    self.logger.error("Handshake send error: \(error.localizedDescription)")
                    #endif
                    print("❌ [LanWebSocketServer] Handshake send error: \(error.localizedDescription)")
                    self.closeConnection(connectionId)
                    return
                }
                context.upgraded = true
                #if canImport(os)
                self.logger.info("✅ CLIPBOARD HANDSHAKE COMPLETE: WebSocket upgraded for \(connectionId.uuidString.prefix(8))")
                #endif
                print("✅ [LanWebSocketServer] CLIPBOARD HANDSHAKE COMPLETE: WebSocket upgraded, starting frame reception")
                try? "✅ [LanWebSocketServer] CLIPBOARD HANDSHAKE COMPLETE: WebSocket upgraded\n".appendToFile(path: "/tmp/hypo_debug.log")
                self.delegate?.server(self, didAcceptConnection: connectionId)
                self.processFrameBuffer(for: connectionId, context: context)
                print("📡 [LanWebSocketServer] CLIPBOARD SETUP: Starting receiveFrameChunk for connection \(connectionId.uuidString.prefix(8))")
                try? "📡 [LanWebSocketServer] CLIPBOARD SETUP: Starting receiveFrameChunk\n".appendToFile(path: "/tmp/hypo_debug.log")
                self.receiveFrameChunk(for: connectionId, context: context)
            }
        })
        return true
    }

    private func receiveFrameChunk(for connectionId: UUID, context: ConnectionContext) {
        #if canImport(os)
        logger.debug("📡 CLIPBOARD RECEIVE: Setting up receive callback for connection \(connectionId.uuidString.prefix(8))")
        #endif
        print("📡 [LanWebSocketServer] CLIPBOARD RECEIVE: Setting up receive callback for \(connectionId.uuidString.prefix(8))")
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    print("⚠️ [LanWebSocketServer] Self is nil in receive callback")
                    return
                }
                guard let context = self.connections[connectionId] else {
                    print("⚠️ [LanWebSocketServer] Connection context not found for \(connectionId.uuidString.prefix(8))")
                    return
                }
                if let error = error {
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
                    print("📥 [LanWebSocketServer] FRAME RECEIVED: \(data.count) bytes from \(connectionId.uuidString.prefix(8))")
                    context.appendToBuffer(data)
                    self.processFrameBuffer(for: connectionId, context: context)
                }
                if isComplete {
                    #if canImport(os)
                    self.logger.info("Connection \(connectionId.uuidString) completed")
                    #endif
                    self.closeConnection(connectionId)
                    return
                }
                self.receiveFrameChunk(for: connectionId, context: context)
            }
        }
    }

    private func processFrameBuffer(for connectionId: UUID, context: ConnectionContext) {
        guard context.upgraded else {
            #if canImport(os)
            logger.debug("⏸️ Frame processing skipped - connection not upgraded: \(connectionId.uuidString)")
            #endif
            return
        }
        while true {
            // Work on a snapshot to avoid races with concurrent appends
            let bufferSnapshot = context.snapshotBuffer()
            guard bufferSnapshot.count >= 2 else {
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
            
            if payloadLength == 126 {
                guard bufferSnapshot.count >= offset + 2 else { return }
                let lengthBytes = bufferSnapshot.subdata(in: offset..<offset + 2)
                payloadLength = Int(readUInt16(from: lengthBytes, offset: 0))
                offset += 2
            } else if payloadLength == 127 {
                guard bufferSnapshot.count >= offset + 8 else { return }
                let lengthBytes = bufferSnapshot.subdata(in: offset..<offset + 8)
                payloadLength = Int(readUInt64(from: lengthBytes, offset: 0))
                offset += 8
            }
            
            let maskLength = isMasked ? 4 : 0
            let requiredLength = offset + maskLength + payloadLength
            guard bufferSnapshot.count >= requiredLength else { return }
            
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
            #if canImport(os)
            logger.info("📦 FRAME PROCESSING: opcode=\(opcode), payload=\(payload.count) bytes, masked=\(isMasked), connection=\(connectionId.uuidString.prefix(8))")
            #endif
            print("📦 [LanWebSocketServer] FRAME PROCESSING: opcode=\(opcode), payload=\(payload.count) bytes")
            handleFrame(opcode: opcode, isFinal: isFinal, payload: payload, connectionId: connectionId, context: context)
        }
    }

    private func handleFrame(opcode: UInt8, isFinal: Bool, payload: Data, connectionId: UUID, context: ConnectionContext) {
        guard isFinal else {
            #if canImport(os)
            logger.warning("⚠️ Fragmented frames are not supported")
            #endif
            return
        }
        switch opcode {
        case 0x1, 0x2:
            #if canImport(os)
            logger.info("📨 FRAME HANDLED: data frame opcode=\(opcode), \(payload.count) bytes from \(connectionId.uuidString.prefix(8))")
            #endif
            print("📨 [LanWebSocketServer] FRAME HANDLED: data frame, \(payload.count) bytes")
            handleReceivedData(payload, from: connectionId)
        case 0x8:
            print("🔌 [LanWebSocketServer] Close frame received from \(connectionId.uuidString)")
            closeConnection(connectionId)
        case 0x9:
            sendFrame(payload: payload, opcode: 0xA, context: context) { _ in }
        case 0xA:
            // Pong - ignore
            break
        default:
            print("⚠️ [LanWebSocketServer] Unsupported opcode \(opcode)")
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
            Task { @MainActor in
                self?.closeConnection(connectionId)
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
        #if canImport(os)
        logger.info("📨 CLIPBOARD DATA RECEIVED: \(data.count) bytes from connection \(connectionId.uuidString.prefix(8))")
        #endif
        print("📨 [LanWebSocketServer] CLIPBOARD DATA RECEIVED: \(data.count) bytes")
        
        // Decode the frame-encoded payload (Android sends: 4-byte length + JSON)
        // Try to decode as TransportFrameCodec frame first (for clipboard messages)
        do {
            let envelope = try frameCodec.decode(data)
            #if canImport(os)
            logger.info("✅ CLIPBOARD FRAME DECODED: envelope type=\(envelope.type.rawValue)")
            #endif
            print("✅ [LanWebSocketServer] CLIPBOARD FRAME DECODED: type=\(envelope.type.rawValue)")
            
            // Handle based on envelope type
            switch envelope.type {
            case .clipboard:
                // Forward the original frame-encoded data to the delegate
                // (it will decode it again in IncomingClipboardHandler)
                #if canImport(os)
                logger.info("✅ CLIPBOARD MESSAGE RECEIVED: forwarding to delegate, \(data.count) bytes")
                #endif
                print("✅ [LanWebSocketServer] CLIPBOARD MESSAGE RECEIVED: \(data.count) bytes, forwarding to delegate")
                delegate?.server(self, didReceiveClipboardData: data, from: connectionId)
                return
            case .control:
                #if canImport(os)
                logger.info("📋 CLIPBOARD CONTROL MESSAGE: ignoring for now")
                #endif
                print("📋 [LanWebSocketServer] CLIPBOARD CONTROL MESSAGE: ignoring")
                return
            }
        } catch let decodingError as DecodingError {
            // Detailed decoding error logging
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
            print("⚠️ [LanWebSocketServer] CLIPBOARD FRAME DECODE FAILED: DecodingError")
            switch decodingError {
            case .typeMismatch(let type, let context):
                print("   Type mismatch: expected \(String(describing: type)) at path: \(context.codingPath.map { $0.stringValue })")
            case .keyNotFound(let key, let context):
                print("   Key not found: \(key.stringValue) at path: \(context.codingPath.map { $0.stringValue })")
            case .valueNotFound(let type, let context):
                print("   Value not found: \(String(describing: type)) at path: \(context.codingPath.map { $0.stringValue })")
            case .dataCorrupted(let context):
                print("   Data corrupted: \(context.debugDescription) at path: \(context.codingPath.map { $0.stringValue })")
            @unknown default:
                print("   Unknown decoding error")
            }
            print("   Data size: \(data.count) bytes")
            if data.count >= 4 {
                let lengthBytes = data.prefix(4)
                let lengthValue = lengthBytes.withUnsafeBytes { buffer -> UInt32 in
                    buffer.load(as: UInt32.self)
                }
                let length = Int(UInt32(bigEndian: lengthValue))
                print("   First 4 bytes as length: \(length) (data has \(data.count) bytes)")
                if data.count > 4 && length > 0 && length <= data.count - 4 {
                    let jsonData = data.subdata(in: 4..<(4 + length))
                    if let jsonString = String(data: jsonData, encoding: .utf8) {
                        print("   Full JSON: \(jsonString)")
                    }
                }
            }
        } catch {
            // Other errors
            #if canImport(os)
            logger.error("⚠️ CLIPBOARD FRAME DECODE FAILED: \(error.localizedDescription)")
            logger.error("   Error type: \(String(describing: type(of: error)))")
            #endif
            print("⚠️ [LanWebSocketServer] CLIPBOARD FRAME DECODE FAILED: \(error.localizedDescription)")
            print("   Error type: \(String(describing: type(of: error)))")
        }
        
        // Fall back to direct JSON parsing for pairing messages
        let messageType = detectMessageType(data)
        
        #if canImport(os)
        logger.info("📋 CLIPBOARD MESSAGE TYPE: \(String(describing: messageType))")
        #endif
        print("📋 [LanWebSocketServer] CLIPBOARD MESSAGE TYPE: \(String(describing: messageType))")
        
        switch messageType {
        case .pairing:
            // Log JSON before attempting decode
            #if canImport(os)
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.info("🔍 CLIPBOARD PAIRING MESSAGE: \(jsonString.prefix(200))")
            }
            #endif
            print("🔍 [LanWebSocketServer] CLIPBOARD PAIRING MESSAGE detected")
            do {
                try handlePairingMessage(data, from: connectionId)
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
                print("❌ ERROR: Pairing message decoding failed: \(decodingError)")
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("   Raw JSON: \(jsonString)")
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
                print("❌ ERROR: Pairing message handling failed: \(error)")
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("   Raw JSON: \(jsonString)")
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
            print("✅ [LanWebSocketServer] CLIPBOARD MESSAGE RECEIVED (fallback): \(data.count) bytes, forwarding to delegate")
            delegate?.server(self, didReceiveClipboardData: data, from: connectionId)
        case .unknown:
            #if canImport(os)
            logger.warning("⚠️ CLIPBOARD UNKNOWN MESSAGE TYPE from \(connectionId.uuidString.prefix(8)), \(data.count) bytes")
            #endif
            print("⚠️ [LanWebSocketServer] CLIPBOARD UNKNOWN MESSAGE TYPE: \(data.count) bytes")
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
            return .unknown
        }
        
        #if canImport(os)
        // Log the raw JSON for debugging
        if let jsonString = String(data: data, encoding: .utf8) {
            logger.info("📥 Received JSON: \(jsonString)")
        }
        logger.info("📋 JSON keys: \(Array(json.keys).sorted().joined(separator: ", "))")
        #endif
        
        // Pairing messages have android_device_id and android_pub_key (even if challenge_id is missing)
        // Check for pairing-specific fields
        if json["android_device_id"] != nil && json["android_pub_key"] != nil {
            #if canImport(os)
            logger.info("✅ Detected pairing message (has android_device_id and android_pub_key)")
            #endif
            return .pairing
        }
        
        // Also check for challenge_id if present
        if json["challenge_id"] != nil {
            #if canImport(os)
            logger.info("✅ Detected pairing message (has challenge_id)")
            #endif
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
        logger.info("✅ Decoded pairing challenge from device: \(challenge.androidDeviceName)")
        #endif
        delegate?.server(self, didReceivePairingChallenge: challenge, from: connectionId)
    }
    
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            #if canImport(os)
            logger.info("WebSocket server ready")
            #endif
            print("✅ [LanWebSocketServer] Server is ready and listening")
        case .failed(let error):
            #if canImport(os)
            logger.error("WebSocket server failed: \(error.localizedDescription)")
            #endif
            print("❌ [LanWebSocketServer] Server failed: \(error.localizedDescription)")
        case .cancelled:
            #if canImport(os)
            logger.info("WebSocket server cancelled")
            #endif
            print("🔌 [LanWebSocketServer] Server cancelled")
        case .waiting(let error):
            print("⏳ [LanWebSocketServer] Server waiting: \(error.localizedDescription)")
        default:
            #if canImport(os)
            logger.debug("WebSocket server state: \(String(describing: state))")
            #endif
            print("🟡 [LanWebSocketServer] Server state: \(String(describing: state))")
        }
    }
    
    // Connection state is now handled in handleNewConnection's stateUpdateHandler
    // This method is kept for backward compatibility but may not be called
    
    private func closeConnection(_ id: UUID) {
        let deviceId = connectionMetadata[id]?.deviceId ?? "unknown"
        let closeMsg = "🔌 [LanWebSocketServer] closeConnection called: \(id.uuidString.prefix(8)), deviceId=\(deviceId)\n"
        print(closeMsg)
        try? closeMsg.appendToFile(path: "/tmp/hypo_debug.log")
        connections[id]?.connection.cancel()
        connections.removeValue(forKey: id)
        connectionMetadata.removeValue(forKey: id)
        delegate?.server(self, didCloseConnection: id)
        
        #if canImport(os)
        logger.info("Connection closed: \(id.uuidString)")
        #endif
    }
}
