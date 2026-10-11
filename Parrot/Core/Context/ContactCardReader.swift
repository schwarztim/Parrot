import Contacts
import Foundation

/// Reads the user's own Contacts card ("Me") for the USER INFORMATION
/// section. [LLM]
///
/// Only used when the user turns on "Include my contact card". Permission
/// is asked for then (never at launch or mid-dictation), and only when the
/// app declares `NSContactsUsageDescription`: asking without it would
/// terminate the app. Without access the account's full name is used.
/// The card is read once and cached; `refresh()` reads it again.
@MainActor
final class ContactCardReader {

    private(set) var cached: UserIdentity?

    init() {}

    /// Whether the app may ask for Contacts access at all.
    static var canRequestAccess: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil
    }

    static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// Asks for Contacts access (shows the system prompt once). Returns
    /// whether access is granted. Never asks when the usage text is missing.
    func requestAccess() async -> Bool {
        if Self.isAuthorized { return true }
        guard Self.canRequestAccess else {
            diagLog("[Parrot:Context] Contacts access not requested: NSContactsUsageDescription is missing")
            return false
        }
        let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
        if granted { await refresh() }
        return granted
    }

    /// Reads the Me card again, off the main thread. No prompt: does nothing
    /// without access.
    func refresh() async {
        guard Self.isAuthorized else { return }
        let card = await Task.detached(priority: .utility) { () -> UserIdentity? in
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
            ]
            guard let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys) else { return nil }
            let name = [me.givenName, me.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return UserIdentity(
                fullName: name.isEmpty ? nil : name,
                email: me.emailAddresses.first.map { $0.value as String },
                phone: me.phoneNumbers.first?.value.stringValue
            )
        }.value
        cached = card
    }

    /// The cached card, or the account's full name when there is none.
    func identity() -> UserIdentity {
        if let cached, !cached.isEmpty { return cached }
        let name = NSFullUserName()
        return UserIdentity(fullName: name.isEmpty ? nil : name)
    }
}
