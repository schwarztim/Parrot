import Foundation
import SystemConfiguration

/// The SYSTEM CONTEXT section: time, time zone, locale and computer name at
/// the moment recording started. [LLM]
struct SystemSnapshot: Equatable, Sendable {
    var currentTime: String
    var timeZone: String
    var locale: String
    var computerName: String?

    /// The values right now. The time uses a fixed, unambiguous format
    /// ("2026-10-10 14:05 (Saturday)") in the user's time zone.
    static func capture(
        now: Date = Date(),
        timeZone: TimeZone = .current,
        locale: Locale = .current,
        computerName: String? = SystemSnapshot.computerName()
    ) -> SystemSnapshot {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm (EEEE)"
        return SystemSnapshot(
            currentTime: formatter.string(from: now),
            timeZone: timeZone.identifier,
            locale: locale.identifier,
            computerName: computerName
        )
    }

    /// The name set in System Settings > General > Sharing.
    static func computerName() -> String? {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty else { return nil }
        return name
    }
}

/// The USER INFORMATION section, from the Contacts "Me" card. [LLM]
struct UserIdentity: Equatable, Sendable {
    var fullName: String?
    var email: String?
    var phone: String?

    var isEmpty: Bool {
        [fullName, email, phone].allSatisfy { ($0 ?? "").isEmpty }
    }
}
