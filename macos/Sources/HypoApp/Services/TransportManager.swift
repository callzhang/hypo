import Foundation

public enum TransportPreference: String, Codable {
    case lanFirst
    case cloudOnly
}

public protocol TransportProvider {
    func preferredTransport(for preference: TransportPreference) -> SyncTransport
}

public final class TransportManager {
    private let provider: TransportProvider
    private let preferenceStorage: PreferenceStorage

    public init(provider: TransportProvider, preferenceStorage: PreferenceStorage = UserDefaultsPreferenceStorage()) {
        self.provider = provider
        self.preferenceStorage = preferenceStorage
    }

    public func loadTransport() -> SyncTransport {
        let preference = preferenceStorage.loadPreference() ?? .lanFirst
        return provider.preferredTransport(for: preference)
    }

    public func update(preference: TransportPreference) {
        preferenceStorage.savePreference(preference)
    }
}

public protocol PreferenceStorage {
    func loadPreference() -> TransportPreference?
    func savePreference(_ preference: TransportPreference)
}

public struct UserDefaultsPreferenceStorage: PreferenceStorage {
    private let key = "transport_preference"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadPreference() -> TransportPreference? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return TransportPreference(rawValue: raw)
    }

    public func savePreference(_ preference: TransportPreference) {
        defaults.set(preference.rawValue, forKey: key)
    }
}
