import Foundation

// Helper function to add base64 padding if missing (Android uses Base64.withoutPadding())
private func addBase64Padding(_ base64: String) -> String {
    let remainder = base64.count % 4
    guard remainder != 0 else { return base64 }
    let padding = String(repeating: "=", count: 4 - remainder)
    return base64 + padding
}

// Helper function to decode base64 field with automatic padding
private func decodeBase64Field<T: CodingKey>(
    _ string: String,
    forKey key: T,
    in container: KeyedDecodingContainer<T>
) throws -> Data {
    guard !string.isEmpty else { return Data() }
    let padded = addBase64Padding(string)
    guard let data = Data(base64Encoded: padded) else {
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "Invalid Base64 string for \(key.stringValue)"
        )
    }
    return data
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
    
    // Custom decoder to handle Android's String UUID format
    // Note: TransportFrameCodec uses .convertFromSnakeCase, so snake_case keys are automatically converted to camelCase
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode id as String first (Android sends UUID as string), then convert to UUID
        let idString = try container.decode(String.self, forKey: .id)
        guard let uuid = UUID(uuidString: idString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid UUID format: \(idString)"
            )
        }
        self.id = uuid
        
        // Decode timestamp (Android sends ISO8601 string)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        
        // Decode version
        self.version = try container.decode(String.self, forKey: .version)
        
        // Decode type
        self.type = try container.decode(MessageType.self, forKey: .type)
        
        // Decode payload
        self.payload = try container.decode(Payload.self, forKey: .payload)
    }
    
    // CodingKeys for custom decoder - use camelCase since decoder has .convertFromSnakeCase
    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case version
        case type
        case payload
    }

    public enum MessageType: String, Codable {
        case clipboard
        case control
    }

    public struct Payload: Codable {
        public let contentType: ClipboardPayload.ContentType
        public let ciphertext: Data
        public let deviceId: String  // UUID string (pure UUID, no prefix)
        public let devicePlatform: String?  // Platform: "macos", "android", etc.
        public let deviceName: String?
        public let target: String?
        public let encryption: EncryptionMetadata

        public init(
            contentType: ClipboardPayload.ContentType,
            ciphertext: Data,
            deviceId: String,
            devicePlatform: String? = nil,
            deviceName: String? = nil,
            target: String?,
            encryption: EncryptionMetadata
        ) {
            self.contentType = contentType
            self.ciphertext = ciphertext
            self.deviceId = deviceId
            self.devicePlatform = devicePlatform
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
            self.ciphertext = try decodeBase64Field(ciphertextString, forKey: .ciphertext, in: container)
            
            // Decode deviceId - handle both old format (with prefix) and new format (pure UUID)
            let rawDeviceId = try container.decode(String.self, forKey: .deviceId)
            if rawDeviceId.hasPrefix("macos-") || rawDeviceId.hasPrefix("android-") {
                // Old format: extract UUID from prefixed string
                let prefix = rawDeviceId.hasPrefix("macos-") ? "macos-" : "android-"
                self.deviceId = String(rawDeviceId.dropFirst(prefix.count))
                // Infer platform from prefix if not provided
                self.devicePlatform = rawDeviceId.hasPrefix("macos-") ? "macos" : "android"
            } else {
                // New format: pure UUID
                self.deviceId = rawDeviceId
                self.devicePlatform = try container.decodeIfPresent(String.self, forKey: .devicePlatform)
            }
            
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
            
            // Decode nonce and tag from base64 strings (Android uses standard base64 without padding)
            let nonceString = try container.decode(String.self, forKey: .nonce)
            self.nonce = try decodeBase64Field(nonceString, forKey: .nonce, in: container)
            
            let tagString = try container.decode(String.self, forKey: .tag)
            self.tag = try decodeBase64Field(tagString, forKey: .tag, in: container)
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

    private let logger = HypoLogger(category: "SyncEngine")
    private let transport: SyncTransport
    private let cryptoService: CryptoService
    private let keyProvider: DeviceKeyProviding
    private let localDeviceId: String  // UUID string (pure UUID, no prefix)
    private let localPlatform: DevicePlatform
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
        localPlatform: DevicePlatform = .macOS,
        defaults: UserDefaults = .standard
    ) {
        self.transport = transport
        self.cryptoService = cryptoService
        self.keyProvider = keyProvider
        self.localDeviceId = localDeviceId
        self.localPlatform = localPlatform
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
        // Use the same UserDefaults domain as the app (com.hypo.clipboard)
        let appDefaults = UserDefaults.standard
        let plainTextMode = appDefaults.bool(forKey: "plain_text_mode_enabled")
        
        // Also check the defaults instance passed to SyncEngine for debugging
        let engineDefaultsValue = defaults.bool(forKey: "plain_text_mode_enabled")
        
        logger.info("🔍 [SyncEngine] Plaintext mode check: appDefaults=\(plainTextMode), engineDefaults=\(engineDefaultsValue), using=\(plainTextMode)")
        
        if plainTextMode {
            logger.info("⚠️ [SyncEngine] PLAIN TEXT MODE: Sending without encryption")
        } else {
            logger.info("🔒 [SyncEngine] Encryption mode: Sending encrypted")
        }

        let plaintext = try encoder.encode(payload)
        
        let ciphertext: Data
        let nonce: Data
        let tag: Data
        
        if plainTextMode {
            // Plain text mode: use plaintext directly as "ciphertext", with empty nonce/tag
            logger.info("⚠️ [SyncEngine] PLAIN TEXT MODE: Sending unencrypted payload")
            logger.info("   Plaintext content: \(String(data: plaintext.prefix(100), encoding: .utf8) ?? "binary")")
            ciphertext = plaintext
            nonce = Data()
            tag = Data()
            
            logger.info("⚠️ [SyncEngine] PLAIN TEXT MODE: ciphertext=\(ciphertext.count) bytes, nonce=\(nonce.count) bytes, tag=\(tag.count) bytes")
        } else {
            // Normal encryption mode
            let key = try await keyProvider.key(for: targetDeviceId)
            let aad = Data(localDeviceId.utf8)
            let sealed = try await cryptoService.encrypt(plaintext: plaintext, key: key, aad: aad)
            ciphertext = sealed.ciphertext
            nonce = sealed.nonce
            tag = sealed.tag
            
            logger.info("🔒 [SyncEngine] ENCRYPTED: ciphertext=\(ciphertext.count) bytes, nonce=\(nonce.count) bytes, tag=\(tag.count) bytes")
        }

        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: .init(
                contentType: payload.contentType,
                ciphertext: ciphertext,
                deviceId: entry.originDeviceId,  // UUID string (pure UUID)
                devicePlatform: entry.originPlatform?.rawValue ?? localPlatform.rawValue,  // Platform string (use local if not set)
                deviceName: entry.originDeviceName,
                target: targetDeviceId,
                encryption: .init(nonce: nonce, tag: tag)
            )
        )
        
        // Log final envelope state before sending
        logger.info("📦 [SyncEngine] Envelope before send: nonce=\(envelope.payload.encryption.nonce.count) bytes, tag=\(envelope.payload.encryption.tag.count) bytes, ciphertext=\(envelope.payload.ciphertext.count) bytes")
        
        try await transport.send(envelope)
    }

    public func decode(_ data: Data) async throws -> ClipboardPayload {
        // Decode frame-encoded data (4-byte length + JSON) to get envelope
        let frameCodec = TransportFrameCodec()
        let envelope = try frameCodec.decode(data)
        let senderId = envelope.payload.deviceId
        
        // Check if this is a plain text message (empty nonce/tag indicates no encryption)
        let isPlainText = envelope.payload.encryption.nonce.isEmpty || envelope.payload.encryption.tag.isEmpty
        
        let plaintext: Data
        if isPlainText {
            logger.info("⚠️ [SyncEngine] PLAIN TEXT MODE: Receiving unencrypted payload")
            // Use ciphertext directly as plaintext (it's not actually encrypted)
            plaintext = envelope.payload.ciphertext
        } else {
            let key = try await keyProvider.key(for: senderId)
            let keyData = key.withUnsafeBytes { Data($0) }
            logger.info("🔑 [SyncEngine] Loaded key for device \(senderId): \(keyData.count) bytes")
            logger.info("   Key hex (first 16): \(keyData.prefix(16).map { String(format: "%02x", $0) }.joined())")
            
            let aad = Data(senderId.utf8)
            logger.info("🔑 [SyncEngine] AAD: \(senderId) (\(aad.count) bytes)")
            logger.info("   AAD hex: \(aad.map { String(format: "%02x", $0) }.joined())")
            
            logger.info("🔑 [SyncEngine] Ciphertext: \(envelope.payload.ciphertext.count) bytes")
            logger.info("   Ciphertext hex (first 16): \(envelope.payload.ciphertext.prefix(16).map { String(format: "%02x", $0) }.joined())")
            
            logger.info("🔑 [SyncEngine] Nonce: \(envelope.payload.encryption.nonce.count) bytes")
            logger.info("   Nonce hex: \(envelope.payload.encryption.nonce.map { String(format: "%02x", $0) }.joined())")
            
            logger.info("🔑 [SyncEngine] Tag: \(envelope.payload.encryption.tag.count) bytes")
            logger.info("   Tag hex: \(envelope.payload.encryption.tag.map { String(format: "%02x", $0) }.joined())")
            
            do {
                plaintext = try await cryptoService.decrypt(
                    ciphertext: envelope.payload.ciphertext,
                    key: key,
                    nonce: envelope.payload.encryption.nonce,
                    tag: envelope.payload.encryption.tag,
                    aad: aad
                )
                logger.info("✅ [SyncEngine] Decrypted plaintext: \(plaintext.count) bytes")
                if let plaintextString = String(data: plaintext, encoding: .utf8) {
                    logger.info("🔍 [SyncEngine] Decrypted plaintext JSON: \(plaintextString)")
                }
            } catch {
                logger.info("❌ [SyncEngine] Decryption failed: \(error)")
                logger.info("   Error type: \(String(describing: type(of: error)))")
                throw error
            }
        }
        
        let payload = try decoder.decode(ClipboardPayload.self, from: plaintext)
        logger.info("✅ [SyncEngine] ClipboardPayload decoded successfully: type=\(payload.contentType.rawValue), data=\(payload.data.count) bytes")
        return payload
    }
}
