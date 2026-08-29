import Foundation

/// Key-value store backing the clipboard history.
///
/// The shape mirrors exactly what HistoryStore already asks of UserDefaults:
/// a Data blob for the entries, a Bool flag for the file storage migration,
/// and removal of the entries key.
///
/// macOS keeps using UserDefaults. iOS cannot: the main app, the share
/// extension and the notification service extension all write history, and a
/// UserDefaults App Group suite does not reliably propagate writes across
/// processes. iOS injects a file-backed implementation guarded by
/// NSFileCoordinator instead.
public protocol HistoryPersistence: Sendable {
    func data(forKey key: String) throws -> Data?
    func setData(_ data: Data, forKey key: String) throws
    func removeValue(forKey key: String) throws
    func bool(forKey key: String) -> Bool
    func setBool(_ value: Bool, forKey key: String)
}

/// Default macOS behaviour, backed by UserDefaults.
public struct UserDefaultsHistoryPersistence: HistoryPersistence {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(forKey key: String) throws -> Data? {
        defaults.data(forKey: key)
    }

    public func setData(_ data: Data, forKey key: String) throws {
        defaults.set(data, forKey: key)
    }

    public func removeValue(forKey key: String) throws {
        defaults.removeObject(forKey: key)
    }

    public func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    public func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Test double. Not used in production code.
public final class InMemoryHistoryPersistence: HistoryPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [String: Data] = [:]
    private var flags: [String: Bool] = [:]

    public init() {}

    public func data(forKey key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return blobs[key]
    }

    public func setData(_ data: Data, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        blobs[key] = data
    }

    public func removeValue(forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        blobs.removeValue(forKey: key)
    }

    public func bool(forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return flags[key] ?? false
    }

    public func setBool(_ value: Bool, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        flags[key] = value
    }
}
