import Foundation

public protocol DeviceIdentityProviding { 
    var deviceId: UUID { get }
    var deviceIdString: String { get }
    var deviceName: String { get }
}

public final class DeviceIdentity: DeviceIdentityProviding {
    private enum DefaultsKey {
        static let deviceId = "com.hypo.clipboard.device_id"
        static let deviceName = "com.hypo.clipboard.device_name"
    }
    
    private static let platformPrefix = "macos-"

    public let deviceId: UUID
    public let deviceIdString: String
    public let deviceName: String

    public init(userDefaults: UserDefaults = .standard, hostname: String = Host.current().localizedName ?? "Hypo Mac") {
        // Load or generate device ID
        let uuid: UUID
        if let stored = userDefaults.string(forKey: DefaultsKey.deviceId) {
            // Check if stored value has platform prefix (new format)
            if stored.hasPrefix(Self.platformPrefix) {
                let uuidString = String(stored.dropFirst(Self.platformPrefix.count))
                uuid = UUID(uuidString: uuidString) ?? UUID()
            } else if let parsed = UUID(uuidString: stored) {
                // Legacy format (just UUID), migrate to new format
                uuid = parsed
                let newValue = "\(Self.platformPrefix)\(stored)"
                userDefaults.set(newValue, forKey: DefaultsKey.deviceId)
            } else {
                // Invalid format, generate new
                uuid = UUID()
                let newValue = "\(Self.platformPrefix)\(uuid.uuidString)"
                userDefaults.set(newValue, forKey: DefaultsKey.deviceId)
            }
        } else {
            // Generate new device ID with platform prefix
            uuid = UUID()
            let newValue = "\(Self.platformPrefix)\(uuid.uuidString)"
            userDefaults.set(newValue, forKey: DefaultsKey.deviceId)
        }
        
        deviceId = uuid
        deviceIdString = "\(Self.platformPrefix)\(uuid.uuidString)"
        
        if let storedName = userDefaults.string(forKey: DefaultsKey.deviceName) {
            deviceName = storedName
        } else {
            userDefaults.set(hostname, forKey: DefaultsKey.deviceName)
            deviceName = hostname
        }
    }
}
