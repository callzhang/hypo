import Foundation

public struct SyncEnvelope: Codable {
    public let id: UUID
    public let timestamp: Date
    public let version: String
    public let type: MessageType
    public let payload: Payload

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        version: String = "1.0",
        type: MessageType,
        payload: Payload
    ) {
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
        public let ciphertext: Data
        public let deviceId: String
        public let deviceName: String?
        public let target: String?
        public let encryption: EncryptionMetadata

        public init(
            contentType: ClipboardPayload.ContentType,
            ciphertext: Data,
            deviceId: String,
            deviceName: String? = nil,
            target: String?,
            encryption: EncryptionMetadata
        ) {
            self.contentType = contentType
            self.ciphertext = ciphertext
            self.deviceId = deviceId
            self.deviceName = deviceName
            self.target = target
            self.encryption = encryption
        }
    }

    public struct EncryptionMetadata: Codable {
        public let algorithm: String
        public let nonce: Data
        public let tag: Data

        public init(algorithm: String = "AES-256-GCM", nonce: Data, tag: Data) {
            self.algorithm = algorithm
            self.nonce = nonce
            self.tag = tag
        }
    }
}

public struct ClipboardPayload: Codable {
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
    private let cryptoService: CryptoService
    private let keyProvider: DeviceKeyProviding
    private let localDeviceId: String
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private(set) var state: State = .idle

    public init(
        transport: SyncTransport,
        cryptoService: CryptoService = CryptoService(),
        keyProvider: DeviceKeyProviding,
        localDeviceId: String
    ) {
        self.transport = transport
        self.cryptoService = cryptoService
        self.keyProvider = keyProvider
        self.localDeviceId = localDeviceId
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

    public func transmit(
        entry: ClipboardEntry,
        payload: ClipboardPayload,
        targetDeviceId: String
    ) async throws {
        guard state == .connected else {
            throw NSError(
                domain: "SyncEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Transport not connected"]
            )
        }

        let key = try await keyProvider.key(for: targetDeviceId)
        let plaintext = try encoder.encode(payload)
        let aad = Data(localDeviceId.utf8)
        let sealed = try await cryptoService.encrypt(plaintext: plaintext, key: key, aad: aad)

        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: .init(
                contentType: payload.contentType,
                ciphertext: sealed.ciphertext,
                deviceId: entry.originDeviceId,
                deviceName: entry.originDeviceName,
                target: targetDeviceId,
                encryption: .init(nonce: sealed.nonce, tag: sealed.tag)
            )
        )
        try await transport.send(envelope)
    }

    public func decode(_ data: Data) async throws -> ClipboardPayload {
        let envelope = try decoder.decode(SyncEnvelope.self, from: data)
        let senderId = envelope.payload.deviceId
        let key = try await keyProvider.key(for: senderId)
        let aad = Data(senderId.utf8)
        let plaintext = try await cryptoService.decrypt(
            ciphertext: envelope.payload.ciphertext,
            key: key,
            nonce: envelope.payload.encryption.nonce,
            tag: envelope.payload.encryption.tag,
            aad: aad
        )
        return try decoder.decode(ClipboardPayload.self, from: plaintext)
    }
}
