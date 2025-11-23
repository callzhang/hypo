import Foundation

public struct PairingPayload: Codable, Equatable {
    public let version: String
    public let macDeviceId: UUID
    public let macPublicKey: Data
    public let macSigningPublicKey: Data
    public let service: String
    public let port: Int
    public let relayHint: URL?
    public let issuedAt: Date
    public let expiresAt: Date
    public var signature: Data

    public init(
        version: String = "1",
        macDeviceId: UUID,
        macPublicKey: Data,
        macSigningPublicKey: Data,
        service: String,
        port: Int,
        relayHint: URL?,
        issuedAt: Date,
        expiresAt: Date,
        signature: Data
    ) {
        self.version = version
        self.macDeviceId = macDeviceId
        self.macPublicKey = macPublicKey
        self.macSigningPublicKey = macSigningPublicKey
        self.service = service
        self.port = port
        self.relayHint = relayHint
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case version = "ver"
        case macDeviceId = "mac_device_id"
        case macPublicKey = "mac_pub_key"
        case macSigningPublicKey = "mac_signing_pub_key"
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
        // Encode device ID as pure UUID (no prefix) - platform is handled separately
        let macDeviceIdString = macDeviceId.uuidString.lowercased()
        try container.encode(macDeviceIdString, forKey: .macDeviceId)
        try container.encode(macPublicKey.base64EncodedString(), forKey: .macPublicKey)
        try container.encode(macSigningPublicKey.base64EncodedString(), forKey: .macSigningPublicKey)
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
    
    // Custom decoder to handle both prefixed and non-prefixed formats (backward compatibility)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        
        // Decode device ID - handle both "macos-{UUID}" and legacy "{UUID}" formats
        let macDeviceIdString = try container.decode(String.self, forKey: .macDeviceId)
        let uuidString: String
        if macDeviceIdString.hasPrefix("macos-") {
            uuidString = String(macDeviceIdString.dropFirst(6)) // Remove "macos-" prefix
        } else {
            uuidString = macDeviceIdString // Legacy format
        }
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DecodingError.dataCorruptedError(forKey: .macDeviceId, in: container, debugDescription: "Invalid UUID format: \(macDeviceIdString)")
        }
        macDeviceId = uuid
        
        let macPublicKeyString = try container.decode(String.self, forKey: .macPublicKey)
        guard let macPublicKeyData = Data(base64Encoded: macPublicKeyString) else {
            throw DecodingError.dataCorruptedError(forKey: .macPublicKey, in: container, debugDescription: "Invalid Base64 string for mac_pub_key")
        }
        macPublicKey = macPublicKeyData
        
        let macSigningPublicKeyString = try container.decode(String.self, forKey: .macSigningPublicKey)
        guard let macSigningPublicKeyData = Data(base64Encoded: macSigningPublicKeyString) else {
            throw DecodingError.dataCorruptedError(forKey: .macSigningPublicKey, in: container, debugDescription: "Invalid Base64 string for mac_signing_pub_key")
        }
        macSigningPublicKey = macSigningPublicKeyData
        
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
    public let androidDeviceId: String
    public let androidDeviceName: String
    public let androidPublicKey: Data
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case androidDeviceId = "android_device_id"
        case androidDeviceName = "android_device_name"
        case androidPublicKey = "android_pub_key"
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
        
        self.androidDeviceId = try container.decode(String.self, forKey: .androidDeviceId)
        self.androidDeviceName = try container.decode(String.self, forKey: .androidDeviceName)
        
        // Decode Base64 strings to Data
        let androidPublicKeyString = try container.decode(String.self, forKey: .androidPublicKey)
        guard let androidPublicKeyData = Data(base64Encoded: androidPublicKeyString) else {
            throw DecodingError.dataCorruptedError(forKey: .androidPublicKey, in: container, debugDescription: "Invalid Base64 string for android_pub_key")
        }
        self.androidPublicKey = androidPublicKeyData
        
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
}

public struct PairingAckMessage: Codable, Equatable {
    public let challengeId: UUID
    public let macDeviceId: UUID
    public let macDeviceName: String
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    enum CodingKeys: String, CodingKey {
        case challengeId = "challenge_id"
        case macDeviceId = "mac_device_id"
        case macDeviceName = "mac_device_name"
        case nonce
        case ciphertext
        case tag
    }
    
    // Memberwise initializer for creating instances directly
    public init(challengeId: UUID, macDeviceId: UUID, macDeviceName: String, nonce: Data, ciphertext: Data, tag: Data) {
        self.challengeId = challengeId
        self.macDeviceId = macDeviceId
        self.macDeviceName = macDeviceName
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
    
    // Custom encoder to convert Data to Base64 strings for Android
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Use lowercase UUID string to match Android's UUID.randomUUID().toString() format
        try container.encode(challengeId.uuidString.lowercased(), forKey: .challengeId)
        // Encode device ID as pure UUID (no prefix) to match migration to UUID+platform approach
        let macDeviceIdString = macDeviceId.uuidString.lowercased()
        try container.encode(macDeviceIdString, forKey: .macDeviceId)
        try container.encode(macDeviceName, forKey: .macDeviceName)
        try container.encode(nonce.base64EncodedString(), forKey: .nonce)
        try container.encode(ciphertext.base64EncodedString(), forKey: .ciphertext)
        try container.encode(tag.base64EncodedString(), forKey: .tag)
    }
    
    // Custom decoder to handle both prefixed and non-prefixed formats (backward compatibility)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode challenge ID
        let challengeIdString = try container.decode(String.self, forKey: .challengeId)
        guard let challengeIdUUID = UUID(uuidString: challengeIdString) else {
            throw DecodingError.dataCorruptedError(forKey: .challengeId, in: container, debugDescription: "Invalid UUID format: \(challengeIdString)")
        }
        challengeId = challengeIdUUID
        
        // Decode device ID - handle both "macos-{UUID}" and pure UUID formats
        let macDeviceIdString = try container.decode(String.self, forKey: .macDeviceId)
        let uuidString: String
        if macDeviceIdString.hasPrefix("macos-") {
            uuidString = String(macDeviceIdString.dropFirst(6)) // Remove "macos-" prefix
        } else {
            uuidString = macDeviceIdString // Pure UUID format
        }
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DecodingError.dataCorruptedError(forKey: .macDeviceId, in: container, debugDescription: "Invalid UUID format: \(macDeviceIdString)")
        }
        macDeviceId = uuid
        
        macDeviceName = try container.decode(String.self, forKey: .macDeviceName)
        
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
