import Foundation

// MARK: - SettingsStore

/// Typed reads and writes over one `UserDefaults`, shared by every settings
/// area. Production uses `.standard`; tests pass a suite-named instance.
///
/// A read of a missing key returns the caller's fallback, so loading a
/// settings area never has to write its defaults back.
final class SettingsStore {

    let defaults: UserDefaults

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Reads

    /// True when a value is saved for `key`.
    func contains(_ key: String) -> Bool {
        defaults.object(forKey: key) != nil
    }

    func bool(_ key: String, default fallback: Bool) -> Bool {
        contains(key) ? defaults.bool(forKey: key) : fallback
    }

    func int(_ key: String, default fallback: Int) -> Int {
        contains(key) ? defaults.integer(forKey: key) : fallback
    }

    func double(_ key: String, default fallback: Double) -> Double {
        contains(key) ? defaults.double(forKey: key) : fallback
    }

    func string(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    func string(_ key: String, default fallback: String) -> String {
        defaults.string(forKey: key) ?? fallback
    }

    /// A String-backed enum. A missing or unknown raw value reads as the
    /// fallback.
    func value<T: RawRepresentable>(_ key: String, default fallback: T) -> T where T.RawValue == String {
        defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    /// A JSON-encoded value. Missing or undecodable data reads as nil.
    func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    // MARK: - Writes

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Saves a string; nil removes the key.
    func set(_ value: String?, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Saves a String-backed enum as its raw value.
    func set<T: RawRepresentable>(_ value: T, forKey key: String) where T.RawValue == String {
        defaults.set(value.rawValue, forKey: key)
    }

    /// Saves a value as JSON data; nil removes the key.
    func setEncoded<T: Encodable>(_ value: T?, forKey key: String) {
        if let value, let data = try? encoder.encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - SecretStore

/// Where API keys live: the Keychain in production, memory in tests.
///
/// `read` returns nil when no secret is saved and throws when the store
/// could not be read (a locked keychain over ssh, a denied prompt). A throw
/// is never "empty": callers must not write or delete because a read failed.
protocol SecretStore: AnyObject {
    func read(service: String) throws -> String?
    func write(_ value: String, service: String) throws
    func delete(service: String) throws
}

/// The macOS Keychain: one generic password per service, all under the
/// account "apiKey" (the item names installed users already have).
final class KeychainSecretStore: SecretStore {

    static let account = "apiKey"

    func read(service: String) throws -> String? {
        try KeychainHelper.read(service: service, account: Self.account)
    }

    func write(_ value: String, service: String) throws {
        guard KeychainHelper.save(value, service: service, account: Self.account) else {
            throw KeychainError.writeFailed
        }
    }

    func delete(service: String) throws {
        KeychainHelper.delete(service: service, account: Self.account)
    }
}

/// Secrets held in memory, for tests and previews. Counts every write and
/// delete attempt, and can fail every read like a locked keychain.
final class InMemorySecretStore: SecretStore {

    private(set) var values: [String: String]
    private(set) var writeCount = 0
    private(set) var deleteCount = 0

    /// When set, every read throws this error.
    var readError: Error?

    init(values: [String: String] = [:], readError: Error? = nil) {
        self.values = values
        self.readError = readError
    }

    func read(service: String) throws -> String? {
        if let readError { throw readError }
        return values[service]
    }

    func write(_ value: String, service: String) throws {
        writeCount += 1
        values[service] = value
    }

    func delete(service: String) throws {
        deleteCount += 1
        values[service] = nil
    }
}
