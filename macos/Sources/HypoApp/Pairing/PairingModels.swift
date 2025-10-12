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
}

public struct PairingChallengePayload: Codable, Equatable {
    public let challenge: Data
    public let timestamp: Date
}

public struct PairingAckPayload: Codable, Equatable {
    public let responseHash: Data
    public let issuedAt: Date
}
