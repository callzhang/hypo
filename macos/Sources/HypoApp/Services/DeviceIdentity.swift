import Foundation

public protocol DeviceIdentityProviding { 
    var deviceId: UUID { get }
    var deviceName: String { get }
}

public final class DeviceIdentity: DeviceIdentityProviding {
    private enum DefaultsKey {
        static let deviceId = "com.hypo.clipboard.device_id"
        static let deviceName = "com.hypo.clipboard.device_name"
    }

    public let deviceId: UUID
    public let deviceName: String

    public init(userDefaults: UserDefaults = .standard, hostname: String = Host.current().localizedName ?? "Hypo Mac") {
        if let stored = userDefaults.string(forKey: DefaultsKey.deviceId), let uuid = UUID(uuidString: stored) {
            deviceId = uuid
        } else {
            let uuid = UUID()
            userDefaults.set(uuid.uuidString, forKey: DefaultsKey.deviceId)
            deviceId = uuid
        }
        if let storedName = userDefaults.string(forKey: DefaultsKey.deviceName) {
            deviceName = storedName
        } else {
            userDefaults.set(hostname, forKey: DefaultsKey.deviceName)
            deviceName = hostname
        }
    }
}
