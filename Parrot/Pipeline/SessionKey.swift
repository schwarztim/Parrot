import Foundation

/// A typed slot in a session's attachment bag.
///
/// Swift extensions cannot add stored properties, so an area that needs
/// private per-session state declares a key and a computed property in its
/// own file:
///
/// ```swift
/// private enum PasteTargetKey: SessionKey {
///     static let defaultValue: pid_t? = nil
/// }
///
/// extension DictationSession {
///     var pasteTarget: pid_t? {
///         get { self[PasteTargetKey.self] }
///         set { self[PasteTargetKey.self] = newValue }
///     }
/// }
/// ```
protocol SessionKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// Storage behind `DictationSession`'s subscript, keyed by key type.
@MainActor
final class SessionAttachments {
    private var values: [ObjectIdentifier: Any] = [:]

    subscript<Key: SessionKey>(key: Key.Type) -> Key.Value {
        get { values[ObjectIdentifier(key)] as? Key.Value ?? Key.defaultValue }
        set { values[ObjectIdentifier(key)] = newValue }
    }
}

extension DictationSession {
    /// Reads or writes the value stored under `key`, or its default.
    subscript<Key: SessionKey>(key: Key.Type) -> Key.Value {
        get { attachments[key] }
        set { attachments[key] = newValue }
    }
}
