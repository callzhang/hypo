import Foundation

/// Represents a device that has been paired with this local device.
public struct PairedDevice: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let platform: String
    public var lastSeen: Date
    public var isOnline: Bool

    // Bonjour/discovery information
    public let serviceName: String?
    public let bonjourHost: String?
    public let bonjourPort: Int?
    public let fingerprint: String?
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        platform: String,
        lastSeen: Date,
        isOnline: Bool,
        serviceName: String? = nil,
        bonjourHost: String? = nil,
        bonjourPort: Int? = nil,
        fingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.lastSeen = lastSeen
        self.isOnline = isOnline
        self.serviceName = serviceName
        self.bonjourHost = bonjourHost
        self.bonjourPort = bonjourPort
        self.fingerprint = fingerprint
    }
    
    /// Create a PairedDevice from a DiscoveredPeer
    public init(from peer: DiscoveredPeer, name: String, platform: String) {
        self.id = peer.endpoint.metadata["device_id"] ?? peer.serviceName
        self.name = name
        self.platform = platform
        self.lastSeen = peer.lastSeen
        self.isOnline = true
        self.serviceName = peer.serviceName
        self.bonjourHost = peer.endpoint.host
        self.bonjourPort = peer.endpoint.port
        self.fingerprint = peer.endpoint.fingerprint
    }
    
    /// Update with discovery information from a DiscoveredPeer
    public func updating(from peer: DiscoveredPeer) -> PairedDevice {
        PairedDevice(
            id: self.id,
            name: self.name,
            platform: self.platform,
            lastSeen: max(self.lastSeen, peer.lastSeen),
            isOnline: self.isOnline,
            serviceName: peer.serviceName,
            bonjourHost: peer.endpoint.host,
            bonjourPort: peer.endpoint.port,
            fingerprint: peer.endpoint.fingerprint
        )
    }
}
