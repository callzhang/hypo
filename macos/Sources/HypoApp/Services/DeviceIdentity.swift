import Foundation

public enum DevicePlatform: String, Codable {
    case macOS = "macos"
    case Android = "android"
    case iOS = "ios"
    case Windows = "windows"
    case Linux = "linux"
}

public protocol DeviceIdentityProviding { 
    var deviceId: UUID { get }
    var deviceIdString: String { get }  // UUID string for protocol compatibility
    var platform: DevicePlatform { get }
    var deviceName: String { get }
}

public final class DeviceIdentity: DeviceIdentityProviding {
    private enum DefaultsKey {
        static let deviceId = "com.hypo.clipboard.device_id"
        static let devicePlatform = "com.hypo.clipboard.device_platform"
        static let deviceName = "com.hypo.clipboard.device_name"
    }
    

    private static let currentPlatform = DevicePlatform.macOS

    public let deviceId: UUID
    public let platform: DevicePlatform
    public let deviceName: String
    
    /// UUID string for protocol compatibility (backward compatibility during migration)
    /// Normalized to lowercase for cross-platform compatibility (Android uses lowercase UUIDs)
    public var deviceIdString: String {
        deviceId.uuidString.lowercased()
    }

    public init(userDefaults: UserDefaults = .standard, hostname: String = Host.current().localizedName ?? "Hypo Mac") {
        // Load or generate device ID (migrate from prefixed format if needed)
        let uuid: UUID
        if let stored = userDefaults.string(forKey: DefaultsKey.deviceId), let parsed = UUID(uuidString: stored) {
            // New format: pure UUID
            uuid = parsed
            // Ensure platform is set
            if userDefaults.string(forKey: DefaultsKey.devicePlatform) == nil {
                userDefaults.set(Self.currentPlatform.rawValue, forKey: DefaultsKey.devicePlatform)
            }
        } else {
            // Invalid format or missing, generate new
            uuid = UUID()
            userDefaults.set(uuid.uuidString, forKey: DefaultsKey.deviceId)
            userDefaults.set(Self.currentPlatform.rawValue, forKey: DefaultsKey.devicePlatform)
        }
        
        deviceId = uuid
        
        // Load platform (default to macOS if not set)
        if let platformString = userDefaults.string(forKey: DefaultsKey.devicePlatform),
           let platform = DevicePlatform(rawValue: platformString) {
            self.platform = platform
        } else {
            self.platform = Self.currentPlatform
            userDefaults.set(Self.currentPlatform.rawValue, forKey: DefaultsKey.devicePlatform)
        }
        
        if let storedName = userDefaults.string(forKey: DefaultsKey.deviceName) {
            deviceName = storedName
        } else {
            userDefaults.set(hostname, forKey: DefaultsKey.deviceName)
            deviceName = hostname
        }
    }
}
