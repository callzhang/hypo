import Foundation

public struct SyncEnvelope: Codable {
    public let id: UUID
    public let timestamp: Date
    public let version: String
    public let type: MessageType
    public let payload: Payload

    public init(id: UUID = UUID(), timestamp: Date = Date(), version: String = "1.0", type: MessageType, payload: Payload) {
        self.id = id
        self.timestamp = timestamp
        self.version = version
        self.type = type
        self.payload = payload
    }

    public enum MessageType: String, Codable {
        case clipboard
        case control
    }

    public struct Payload: Codable {
        public let contentType: ClipboardPayload.ContentType
        public let data: Data
        public let metadata: [String: String]?
        public let deviceId: String
        public let nonce: Data
        public let tag: Data

        public init(contentType: ClipboardPayload.ContentType, data: Data, metadata: [String: String]? = nil, deviceId: String, nonce: Data, tag: Data) {
            self.contentType = contentType
            self.data = data
            self.metadata = metadata
            self.deviceId = deviceId
            self.nonce = nonce
            self.tag = tag
        }
    }
}

public struct ClipboardPayload {
    public enum ContentType: String, Codable {
        case text
        case link
        case image
        case file
    }

    public let contentType: ContentType
    public let data: Data
    public let metadata: [String: String]?

    public init(contentType: ContentType, data: Data, metadata: [String: String]? = nil) {
        self.contentType = contentType
        self.data = data
        self.metadata = metadata
    }
}

public protocol SyncTransport {
    func connect() async throws
    func send(_ envelope: SyncEnvelope) async throws
    func disconnect() async
}

public final actor SyncEngine {
    public enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private let transport: SyncTransport
    private let decoder = JSONDecoder()
    private(set) var state: State = .idle

    public init(transport: SyncTransport) {
        self.transport = transport
    }

    public func establishConnection() async {
        state = .connecting
        do {
            try await transport.connect()
            state = .connected
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func transmit(entry: ClipboardEntry, payload: ClipboardPayload) async throws {
        guard state == .connected else {
            throw NSError(domain: "SyncEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transport not connected"])
        }

        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: .init(
                contentType: payload.contentType,
                data: payload.data,
                metadata: payload.metadata,
                deviceId: entry.originDeviceId,
                nonce: Data(),
                tag: Data()
            )
        )
        try await transport.send(envelope)
    }

    public func decode(_ data: Data) throws -> ClipboardPayload {
        let envelope = try decoder.decode(SyncEnvelope.self, from: data)
        return ClipboardPayload(contentType: envelope.payload.contentType, data: envelope.payload.data, metadata: envelope.payload.metadata)
    }
}
