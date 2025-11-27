import Foundation

public struct PairingPayload: Codable, Equatable {
    public let version: String
    public let peerDeviceId: UUID
    public let peerPublicKey: Data
    public let peerSigningPublicKey: Data
    public let service: String
    public let port: Int
    public let relayHint: URL?
    public let issuedAt: Date
    public let expiresAt: Date
    public var signature: Data

    public init(
        version: String = "1",
        peerDeviceId: UUID,
        peerPublicKey: Data,
        peerSigningPublicKey: Data,
        service: String,
        port: Int,
        relayHint: URL?,
        issuedAt: Date,
        expiresAt: Date,
        signature: Data
    ) {
        self.version = version
        self.peerDeviceId = peerDeviceId
        self.peerPublicKey = peerPublicKey
        self.peerSigningPublicKey = peerSigningPublicKey
        self.service = service
        self.port = port
        self.relayHint = relayHint
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case version = "ver"
        case peerDeviceId = "peer_device_id"
        case peerPublicKey = "peer_pub_key"
        case peerSigningPublicKey = "peer_signing_pub_key"
        case service
        case port
        case relayHint = "relay_hint"
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case signature
    }
    
    // Custom encoder - use pure UUID (no prefix) to match migration to UUID+platform approach
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        // Encode device ID as pure UUID (no prefix) and preserve original casing
        let peerDeviceIdString = peerDeviceId.uuidString
        try container.encode(peerDeviceIdString, forKey: .peerDeviceId)
        try container.encode(peerPublicKey.base64EncodedString(), forKey: .peerPublicKey)
        try container.encode(peerSigningPublicKey.base64EncodedString(), forKey: .peerSigningPublicKey)
        try container.encode(service, forKey: .service)
        try container.encode(port, forKey: .port)
        if let relayHint = relayHint {
            try container.encode(relayHint.absoluteString, forKey: .relayHint)
        }
        let dateFormatter = ISO8601DateFormatter()
        try container.encode(dateFormatter.string(from: issuedAt), forKey: .issuedAt)
        try container.encode(dateFormatter.string(from: expiresAt), forKey: .expiresAt)
        try container.encode(signature.base64EncodedString(), forKey: .signature)
    }
    
    // Custom decoder to handle platform-prefixed formats (macos-{UUID}, android-{UUID}, etc.)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        
        // Decode device ID - handle platform-prefixed formats
        let deviceIdString = try container.decode(String.self, forKey: .peerDeviceId)
        let uuidString: String
        if deviceIdString.hasPrefix("macos-") {
            uuidString = String(deviceIdString.dropFirst(6)) // Remove "macos-" prefix
        } else if deviceIdString.hasPrefix("android-") {
            uuidString = String(deviceIdString.dropFirst(8)) // Remove "android-" prefix
        } else {
            uuidString = deviceIdString // Pure UUID format
        }
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DecodingError.dataCorruptedError(forKey: .peerDeviceId, in: container, debugDescription: "Invalid UUID format: \(deviceIdString)")
        }
        peerDeviceId = uuid
        
        // Decode public key
        let publicKeyString = try container.decode(String.self, forKey: .peerPublicKey)
        guard let publicKeyData = Data(base64Encoded: publicKeyString) else {
            throw DecodingError.dataCorruptedError(forKey: .peerPublicKey, in: container, debugDescription: "Invalid Base64 string for peer_pub_key")
        }
        peerPublicKey = publicKeyData
        
        // Decode signing public key
        let signingPublicKeyString = try container.decode(String.self, forKey: .peerSigningPublicKey)
        guard let signingPublicKeyData = Data(base64Encoded: signingPublicKeyString) else {
            throw DecodingError.dataCorruptedError(forKey: .peerSigningPublicKey, in: container, debugDescription: "Invalid Base64 string for peer_signing_pub_key")
        }
        peerSigningPublicKey = signingPublicKeyData
        
        service = try container.decode(String.self, forKey: .service)
        port = try container.decode(Int.self, forKey: .port)
        relayHint = try container.decodeIfPresent(String.self, forKey: .relayHint).flatMap { URL(string: $0) }
        
        let dateFormatter = ISO8601DateFormatter()
        let issuedAtString = try container.decode(String.self, forKey: .issuedAt)
        guard let issuedAtDate = dateFormatter.date(from: issuedAtString) else {
            throw DecodingError.dataCorruptedError(forKey: .issuedAt, in: container, debugDescription: "Invalid ISO8601 date string for issued_at")
        }
        issuedAt = issuedAtDate
        
        let expiresAtString = try container.decode(String.self, forKey: .expiresAt)
        guard let expiresAtDate = dateFormatter.date(from: expiresAtString) else {
            throw DecodingError.dataCorruptedError(forKey: .expiresAt, in: container, debugDescription: "Invalid ISO8601 date string for expires_at")
        }
        expiresAt = expiresAtDate
        
        let signatureString = try container.decode(String.self, forKey: .signature)
        guard let signatureData = Data(base64Encoded: signatureString) else {
            throw DecodingError.dataCorruptedError(forKey: .signature, in: container, debugDescription: "Invalid Base64 string for signature")
        }
        signature = signatureData
    }
}

public struct PairingChallengeMessage: Codable, Equatable {
    public let challengeId: UUID
    public let initiatorDeviceId: String
    public let initiatorDeviceName: String
    public let initiatorPublicKey: Data
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case initiatorDeviceId = "initiator_device_id"
        case initiatorDeviceName = "initiator_device_name"
        case initiatorPublicKey = "initiator_pub_key"
        case nonce
        case ciphertext
        case tag
    }
    
    // Custom decoder to handle Base64 strings from Android
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Handle challengeId as String UUID from Android (optional because Android may not include it with encodeDefaults=false)
        let challengeId: UUID
        if let challengeIdString = try? container.decode(String.self, forKey: .challengeId),
           let parsedId = UUID(uuidString: challengeIdString) {
            challengeId = parsedId
        } else {
            // Generate a new UUID if not provided (Android uses encodeDefaults=false so default values aren't serialized)
            challengeId = UUID()
        }
        self.challengeId = challengeId
        
        // Decode device ID
        self.initiatorDeviceId = try container.decode(String.self, forKey: .initiatorDeviceId)
        
        // Decode device name
        self.initiatorDeviceName = try container.decode(String.self, forKey: .initiatorDeviceName)
        
        // Decode Base64 strings to Data
        let publicKeyString = try container.decode(String.self, forKey: .initiatorPublicKey)
        guard let publicKeyData = Data(base64Encoded: publicKeyString) else {
            throw DecodingError.dataCorruptedError(forKey: .initiatorPublicKey, in: container, debugDescription: "Invalid Base64 string for initiator_pub_key")
        }
        self.initiatorPublicKey = publicKeyData
        
        let nonceString = try container.decode(String.self, forKey: .nonce)
        guard let nonceData = Data(base64Encoded: nonceString) else {
            throw DecodingError.dataCorruptedError(forKey: .nonce, in: container, debugDescription: "Invalid Base64 string for nonce")
        }
        self.nonce = nonceData
        
        let ciphertextString = try container.decode(String.self, forKey: .ciphertext)
        guard let ciphertextData = Data(base64Encoded: ciphertextString) else {
            throw DecodingError.dataCorruptedError(forKey: .ciphertext, in: container, debugDescription: "Invalid Base64 string for ciphertext")
        }
        self.ciphertext = ciphertextData
        
        let tagString = try container.decode(String.self, forKey: .tag)
        guard let tagData = Data(base64Encoded: tagString) else {
            throw DecodingError.dataCorruptedError(forKey: .tag, in: container, debugDescription: "Invalid Base64 string for tag")
        }
        self.tag = tagData
    }
    
    // Custom encoder
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Android generates challenge_id in lowercase; use lowercase for compatibility
        try container.encode(challengeId.uuidString.lowercased(), forKey: .challengeId)
        try container.encode(initiatorDeviceId, forKey: .initiatorDeviceId)
        try container.encode(initiatorDeviceName, forKey: .initiatorDeviceName)
        try container.encode(initiatorPublicKey.base64EncodedString(), forKey: .initiatorPublicKey)
        try container.encode(nonce.base64EncodedString(), forKey: .nonce)
        try container.encode(ciphertext.base64EncodedString(), forKey: .ciphertext)
        try container.encode(tag.base64EncodedString(), forKey: .tag)
    }
}

public struct PairingAckMessage: Codable, Equatable {
    public let challengeId: UUID
    public let responderDeviceId: UUID
    public let responderDeviceName: String
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case responderDeviceId = "responder_device_id"
        case responderDeviceName = "responder_device_name"
        case nonce
        case ciphertext
        case tag
    }
    
    // Memberwise initializer for creating instances directly
    public init(challengeId: UUID, responderDeviceId: UUID, responderDeviceName: String, nonce: Data, ciphertext: Data, tag: Data) {
        self.challengeId = challengeId
        self.responderDeviceId = responderDeviceId
        self.responderDeviceName = responderDeviceName
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
    
    // Custom encoder to convert Data to Base64 strings
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Android stores challenge_id lowercase; keep lowercase to avoid mismatch comparisons
        try container.encode(challengeId.uuidString.lowercased(), forKey: .challengeId)
        // Encode device ID as pure UUID (no prefix) and lowercase to match AAD used in encryption
        let responderDeviceIdString = responderDeviceId.uuidString.lowercased()
        try container.encode(responderDeviceIdString, forKey: .responderDeviceId)
        try container.encode(responderDeviceName, forKey: .responderDeviceName)
        try container.encode(nonce.base64EncodedString(), forKey: .nonce)
        try container.encode(ciphertext.base64EncodedString(), forKey: .ciphertext)
        try container.encode(tag.base64EncodedString(), forKey: .tag)
    }
    
    // Custom decoder to handle platform-prefixed formats
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode challenge ID
        let challengeIdString = try container.decode(String.self, forKey: .challengeId)
        guard let challengeIdUUID = UUID(uuidString: challengeIdString) else {
            throw DecodingError.dataCorruptedError(forKey: .challengeId, in: container, debugDescription: "Invalid UUID format: \(challengeIdString)")
        }
        challengeId = challengeIdUUID
        
        // Decode device ID - handle platform-prefixed formats
        let deviceIdString = try container.decode(String.self, forKey: .responderDeviceId)
        let uuidString: String
        if deviceIdString.hasPrefix("macos-") {
            uuidString = String(deviceIdString.dropFirst(6)) // Remove "macos-" prefix
        } else if deviceIdString.hasPrefix("android-") {
            uuidString = String(deviceIdString.dropFirst(8)) // Remove "android-" prefix
        } else {
            uuidString = deviceIdString // Pure UUID format
        }
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DecodingError.dataCorruptedError(forKey: .responderDeviceId, in: container, debugDescription: "Invalid UUID format: \(deviceIdString)")
        }
        responderDeviceId = uuid
        
        // Decode device name
        responderDeviceName = try container.decode(String.self, forKey: .responderDeviceName)
        
        // Decode Base64 strings to Data
        let nonceString = try container.decode(String.self, forKey: .nonce)
        guard let nonceData = Data(base64Encoded: nonceString) else {
            throw DecodingError.dataCorruptedError(forKey: .nonce, in: container, debugDescription: "Invalid Base64 string for nonce")
        }
        nonce = nonceData
        
        let ciphertextString = try container.decode(String.self, forKey: .ciphertext)
        guard let ciphertextData = Data(base64Encoded: ciphertextString) else {
            throw DecodingError.dataCorruptedError(forKey: .ciphertext, in: container, debugDescription: "Invalid Base64 string for ciphertext")
        }
        ciphertext = ciphertextData
        
        let tagString = try container.decode(String.self, forKey: .tag)
        guard let tagData = Data(base64Encoded: tagString) else {
            throw DecodingError.dataCorruptedError(forKey: .tag, in: container, debugDescription: "Invalid Base64 string for tag")
        }
        tag = tagData
    }
}

public struct PairingChallengePayload: Codable, Equatable {
    public let challenge: Data
    public let timestamp: Date
}

public struct PairingAckPayload: Codable, Equatable {
    public let responseHash: Data
    public let issuedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case responseHash = "response_hash"
        case issuedAt = "issued_at"
    }
    
    // Custom encoder to match Android's expected format (snake_case strings)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Convert Data to Base64 string and Date to ISO8601 string
        try container.encode(responseHash.base64EncodedString(), forKey: .responseHash)
        let formatter = ISO8601DateFormatter()
        try container.encode(formatter.string(from: issuedAt), forKey: .issuedAt)
    }
    
    // Custom decoder to handle Base64 string and ISO8601 date
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseHashString = try container.decode(String.self, forKey: .responseHash)
        guard let responseHashData = Data(base64Encoded: responseHashString) else {
            throw DecodingError.dataCorruptedError(forKey: .responseHash, in: container, debugDescription: "Invalid Base64 string for response_hash")
        }
        self.responseHash = responseHashData
        
        let issuedAtString = try container.decode(String.self, forKey: .issuedAt)
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: issuedAtString) else {
            throw DecodingError.dataCorruptedError(forKey: .issuedAt, in: container, debugDescription: "Invalid ISO8601 date string for issued_at")
        }
        self.issuedAt = date
    }
    
    public init(responseHash: Data, issuedAt: Date) {
        self.responseHash = responseHash
        self.issuedAt = issuedAt
    }
}
