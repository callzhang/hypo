import Foundation

public enum TransportFrameError: Error, Equatable {
    case payloadTooLarge
    case truncated
}

public struct TransportFrameCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxPayloadSize: Int

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
        maxPayloadSize: Int = 256 * 1024
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
        let payload = data.subdata(in: MemoryLayout<UInt32>.size..<(MemoryLayout<UInt32>.size + length))
        return try decoder.decode(SyncEnvelope.self, from: payload)
    }
}
