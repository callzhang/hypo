import Foundation

// Helper function to add base64 padding if missing (Android uses Base64.withoutPadding())
private func addBase64Padding(_ base64: String) -> String {
    let remainder = base64.count % 4
    if remainder == 0 {
        return base64
    }
    let padding = String(repeating: "=", count: 4 - remainder)
    return base64 + padding
}

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
        
        // Custom decoding: Android sends base64 strings, macOS expects Data
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contentType = try container.decode(ClipboardPayload.ContentType.self, forKey: .contentType)
            
            // Decode ciphertext from base64 string (Android uses standard base64 without padding)
            let ciphertextString = try container.decode(String.self, forKey: .ciphertext)
            // Android uses Base64.withoutPadding(), so we need to add padding if missing
            let remainder = ciphertextString.count % 4
            let paddedBase64 = remainder == 0 ? ciphertextString : ciphertextString + String(repeating: "=", count: 4 - remainder)
            print("🔍 [SyncEngine] Decoding ciphertext:")
            print("   Original length: \(ciphertextString.count) chars, remainder: \(remainder)")
            print("   Padded length: \(paddedBase64.count) chars")
            print("   First 50 chars: \(ciphertextString.prefix(50))")
            print("   Last 10 chars: \(ciphertextString.suffix(10))")
            guard let ciphertextData = Data(base64Encoded: paddedBase64) else {
                print("❌ [SyncEngine] Failed to decode base64 ciphertext")
                print("   Padded string (first 100): \(paddedBase64.prefix(100))")
                throw DecodingError.dataCorruptedError(forKey: .ciphertext, in: container, debugDescription: "Invalid Base64 string for ciphertext: \(ciphertextString.prefix(50))...")
            }
            print("✅ [SyncEngine] Ciphertext decoded: \(ciphertextData.count) bytes")
            self.ciphertext = ciphertextData
            
            deviceId = try container.decode(String.self, forKey: .deviceId)
            deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
            target = try container.decodeIfPresent(String.self, forKey: .target)
            encryption = try container.decode(EncryptionMetadata.self, forKey: .encryption)
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
        
        // Custom decoding: Android sends base64 strings, macOS expects Data
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            algorithm = try container.decode(String.self, forKey: .algorithm)
            
            // Decode nonce from base64 string (Android uses standard base64 without padding)
            let nonceString = try container.decode(String.self, forKey: .nonce)
            let nonceRemainder = nonceString.count % 4
            let paddedNonce = nonceRemainder == 0 ? nonceString : nonceString + String(repeating: "=", count: 4 - nonceRemainder)
            print("🔍 [SyncEngine] Decoding nonce: \(nonceString) (padded: \(paddedNonce))")
            guard let nonceData = Data(base64Encoded: paddedNonce) else {
                print("❌ [SyncEngine] Failed to decode base64 nonce")
                throw DecodingError.dataCorruptedError(forKey: .nonce, in: container, debugDescription: "Invalid Base64 string for nonce: \(nonceString)")
            }
            print("✅ [SyncEngine] Nonce decoded: \(nonceData.count) bytes")
            self.nonce = nonceData
            
            // Decode tag from base64 string (Android uses standard base64 without padding)
            let tagString = try container.decode(String.self, forKey: .tag)
            let tagRemainder = tagString.count % 4
            let paddedTag = tagRemainder == 0 ? tagString : tagString + String(repeating: "=", count: 4 - tagRemainder)
            print("🔍 [SyncEngine] Decoding tag: \(tagString) (padded: \(paddedTag))")
            guard let tagData = Data(base64Encoded: paddedTag) else {
                print("❌ [SyncEngine] Failed to decode base64 tag")
                throw DecodingError.dataCorruptedError(forKey: .tag, in: container, debugDescription: "Invalid Base64 string for tag: \(tagString)")
            }
            print("✅ [SyncEngine] Tag decoded: \(tagData.count) bytes")
            self.tag = tagData
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
    
    // Custom decoding: Android sends data_base64 (base64 string), macOS expects data (Data)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentType = try container.decode(ContentType.self, forKey: .contentType)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
        
        // Android sends "data_base64" as a base64-encoded string
        if let dataBase64String = try? container.decode(String.self, forKey: .dataBase64) {
            // Android uses Base64.withoutPadding(), so we need to add padding if missing
            let remainder = dataBase64String.count % 4
            let paddedBase64 = remainder == 0 ? dataBase64String : dataBase64String + String(repeating: "=", count: 4 - remainder)
            guard let decodedData = Data(base64Encoded: paddedBase64) else {
                throw DecodingError.dataCorruptedError(forKey: .dataBase64, in: container, debugDescription: "Invalid Base64 string for data_base64")
            }
            self.data = decodedData
        } else if let dataValue = try? container.decode(Data.self, forKey: .data) {
            // Fallback: if "data" field exists (for compatibility)
            self.data = dataValue
        } else {
            throw DecodingError.keyNotFound(CodingKeys.data, DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing both 'data_base64' and 'data' fields"))
        }
    }
    
    // Custom encoding: macOS encodes data as Data, but we can also support data_base64 for compatibility
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(data, forKey: .data)
        // Also encode data_base64 for Android clients that expect this field
        let base64 = data.base64EncodedString()
        try container.encode(base64, forKey: .dataBase64)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
    
    // Use camelCase CodingKeys so JSONDecoder's .convertFromSnakeCase can map snake_case payloads correctly.
    private enum CodingKeys: String, CodingKey {
        case contentType
        case data
        case dataBase64
        case metadata
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

    private let defaults: UserDefaults
    
    public init(
        transport: SyncTransport,
        cryptoService: CryptoService = CryptoService(),
        keyProvider: DeviceKeyProviding,
        localDeviceId: String,
        defaults: UserDefaults = .standard
    ) {
        self.transport = transport
        self.cryptoService = cryptoService
        self.keyProvider = keyProvider
        self.localDeviceId = localDeviceId
        self.defaults = defaults
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

        // Check if plain text mode is enabled
        let plainTextMode = defaults.bool(forKey: "plain_text_mode_enabled")
        
        if plainTextMode {
            print("⚠️ [SyncEngine] PLAIN TEXT MODE: Sending without encryption")
        }

        let plaintext = try encoder.encode(payload)
        
        let ciphertext: Data
        let nonce: Data
        let tag: Data
        
        if plainTextMode {
            // Plain text mode: use plaintext directly as "ciphertext", with empty nonce/tag
            print("⚠️ [SyncEngine] PLAIN TEXT MODE: Sending unencrypted payload")
            print("   Plaintext content: \(String(data: plaintext.prefix(100), encoding: .utf8) ?? "binary")")
            ciphertext = plaintext
            nonce = Data()
            tag = Data()
        } else {
            // Normal encryption mode
            let key = try await keyProvider.key(for: targetDeviceId)
            let aad = Data(localDeviceId.utf8)
            let sealed = try await cryptoService.encrypt(plaintext: plaintext, key: key, aad: aad)
            ciphertext = sealed.ciphertext
            nonce = sealed.nonce
            tag = sealed.tag
        }

        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: .init(
                contentType: payload.contentType,
                ciphertext: ciphertext,
                deviceId: entry.originDeviceId,
                deviceName: entry.originDeviceName,
                target: targetDeviceId,
                encryption: .init(nonce: nonce, tag: tag)
            )
        )
        try await transport.send(envelope)
    }

    public func decode(_ data: Data) async throws -> ClipboardPayload {
        let envelope = try decoder.decode(SyncEnvelope.self, from: data)
        let senderId = envelope.payload.deviceId
        
        // Check if this is a plain text message (empty nonce/tag indicates no encryption)
        let isPlainText = envelope.payload.encryption.nonce.isEmpty || envelope.payload.encryption.tag.isEmpty
        
        let plaintext: Data
        if isPlainText {
            print("⚠️ [SyncEngine] PLAIN TEXT MODE: Receiving unencrypted payload")
            // Use ciphertext directly as plaintext (it's not actually encrypted)
            plaintext = envelope.payload.ciphertext
        } else {
            let key = try await keyProvider.key(for: senderId)
            let aad = Data(senderId.utf8)
            plaintext = try await cryptoService.decrypt(
                ciphertext: envelope.payload.ciphertext,
                key: key,
                nonce: envelope.payload.encryption.nonce,
                tag: envelope.payload.encryption.tag,
                aad: aad
            )
            print("🔍 [SyncEngine] Decrypted plaintext: \(plaintext.count) bytes")
            if let plaintextString = String(data: plaintext, encoding: .utf8) {
                print("🔍 [SyncEngine] Decrypted plaintext JSON: \(plaintextString)")
            }
        }
        
        let payload = try decoder.decode(ClipboardPayload.self, from: plaintext)
        print("✅ [SyncEngine] ClipboardPayload decoded successfully: type=\(payload.contentType.rawValue), data=\(payload.data.count) bytes")
        return payload
    }
}
