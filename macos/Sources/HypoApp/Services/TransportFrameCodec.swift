import Foundation

public enum TransportFrameError: Error, Equatable {
    case payloadTooLarge
    case truncated
}

public struct TransportFrameCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxPayloadSize: Int
    // Chunk size: 50KB to stay well under actix-ws 64KB limit (leaves room for frame overhead)
    private let chunkSize: Int = 50 * 1024 // 50KB

    public init(
        encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return encoder
        }(),
        decoder: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return decoder
        }(),
        maxPayloadSize: Int = SizeConstants.maxTransportPayloadBytes
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.maxPayloadSize = maxPayloadSize
    }

    public func encode(_ envelope: SyncEnvelope) throws -> Data {
        let payload = try encoder.encode(envelope)
        guard payload.count <= maxPayloadSize else {
            throw TransportFrameError.payloadTooLarge
        }
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        data.append(payload)
        return data
    }
    
    /// Encode envelope, splitting into chunks if necessary
    /// Returns array of frames (single frame for small messages, multiple for large)
    public func encodeWithChunking(_ envelope: SyncEnvelope) throws -> [Data] {
        let payload = try encoder.encode(envelope)
        guard payload.count <= maxPayloadSize else {
            throw TransportFrameError.payloadTooLarge
        }
        
        // If payload fits in one chunk, use normal encoding
        if payload.count <= chunkSize {
            var length = UInt32(payload.count).bigEndian
            var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
            data.append(payload)
            return [data]
        }
        
        // Split into chunks
        let messageId = envelope.id.uuidString.data(using: .utf8) ?? Data()
        let totalChunks = UInt16((payload.count + chunkSize - 1) / chunkSize) // Ceiling division
        
        var chunks: [Data] = []
        for chunkIndex in 0..<totalChunks {
            let start = Int(chunkIndex) * chunkSize
            let end = min(start + chunkSize, payload.count)
            let chunkData = payload[start..<end]
            
            // Chunk frame format:
            // - 1 byte: chunk flag (0x01 = chunked)
            // - 4 bytes: message ID length (big-endian)
            // - message ID (UUID string, UTF-8)
            // - 2 bytes: chunk index (big-endian)
            // - 2 bytes: total chunks (big-endian)
            // - 4 bytes: chunk data length (big-endian)
            // - chunk data
            var chunkFrame = Data()
            chunkFrame.append(0x01) // Chunk flag
            let messageIdLength = UInt32(messageId.count).bigEndian
            chunkFrame.append(contentsOf: withUnsafeBytes(of: messageIdLength) { Data($0) })
            chunkFrame.append(contentsOf: messageId)
            chunkFrame.append(contentsOf: withUnsafeBytes(of: chunkIndex.bigEndian) { Data($0) })
            chunkFrame.append(contentsOf: withUnsafeBytes(of: totalChunks.bigEndian) { Data($0) })
            let chunkLength = UInt32(chunkData.count).bigEndian
            chunkFrame.append(contentsOf: withUnsafeBytes(of: chunkLength) { Data($0) })
            chunkFrame.append(chunkData)
            
            chunks.append(chunkFrame)
        }
        
        return chunks
    }

    public func decode(_ data: Data) throws -> SyncEnvelope {
        guard data.count >= MemoryLayout<UInt32>.size else {
            throw TransportFrameError.truncated
        }
        let lengthRange = 0..<MemoryLayout<UInt32>.size
        let lengthValue = data[lengthRange].withUnsafeBytes { buffer -> UInt32 in
            buffer.load(as: UInt32.self)
        }
        let length = Int(UInt32(bigEndian: lengthValue))
        guard data.count - MemoryLayout<UInt32>.size >= length else {
            throw TransportFrameError.truncated
        }
        guard length <= maxPayloadSize else {
            throw TransportFrameError.payloadTooLarge
        }
        let payload = data.subdata(in: MemoryLayout<UInt32>.size..<(MemoryLayout<UInt32>.size + length))
        return try decoder.decode(SyncEnvelope.self, from: payload)
    }
}
