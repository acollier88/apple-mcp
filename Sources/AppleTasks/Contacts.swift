import ArgumentParser
import Contacts
import Foundation

// IDEAS #17: the People dimension, read-only forever — agents have no
// business editing the address book. Lets triage resolve "meet Sarah
// Tuesday" to a specific person, mail triage rank known senders, and the
// digest surface birthdays. Separate TCC prompt (Contacts); doctor reports
// the grant per host process like every other permission.

struct ContactOut: Codable {
    let id: String
    let name: String
    let nickname: String?
    let organization: String?
    let emails: [String]
    let phones: [String]
    let birthday: String?
    let postalAddresses: [String]

    init(_ c: CNContact) {
        id = c.identifier
        let formatted = CNContactFormatter.string(from: c, style: .fullName)
        name = formatted ?? c.organizationName
        nickname = c.nickname.isEmpty ? nil : c.nickname
        organization = c.organizationName.isEmpty ? nil : c.organizationName
        emails = c.emailAddresses.map { String($0.value) }
        phones = c.phoneNumbers.map { $0.value.stringValue }
        if let b = c.birthday, let month = b.month, let day = b.day {
            birthday = b.year.map { String(format: "%04d-%02d-%02d", $0, month, day) }
                ?? String(format: "%02d-%02d", month, day)
        } else {
            birthday = nil
        }
        postalAddresses = c.postalAddresses.map {
            CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)
                .replacingOccurrences(of: "\n", with: ", ")
        }
    }

    static let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
    ]
}

enum ContactsAccess {
    static func request() async throws -> CNContactStore {
        let store = CNContactStore()
        let granted = try await store.requestAccess(for: .contacts)
        guard granted else {
            throw AppleTasksError.automationFailed(
                "Contacts access denied for this host process. Grant it in "
                + "System Settings > Privacy & Security > Contacts.")
        }
        return store
    }

    static func describeAuthorization() -> String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return "notDetermined (will prompt on first use)"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }
}

struct ContactsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Search Apple Contacts (read-only, always).",
        subcommands: [ContactsSearch.self, ContactsShow.self],
        defaultSubcommand: ContactsSearch.self
    )
}

struct ContactsSearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find contacts by name (or by address when the query contains '@')."
    )

    @Argument(help: "Name fragment, e.g. 'sarah', or an email address.")
    var query: String

    @Option(help: "Max results (default 10).")
    var limit: Int = 10

    func run() async throws {
        let store = try await ContactsAccess.request()
        let predicate = query.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: query)
            : CNContact.predicateForContacts(matchingName: query)
        let matches = try store.unifiedContacts(matching: predicate, keysToFetch: ContactOut.keys)
        emit(matches.prefix(limit).map(ContactOut.init))
    }
}

struct ContactsShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one contact by identifier (from search)."
    )

    @Argument(help: "Contact identifier.")
    var id: String

    func run() async throws {
        let store = try await ContactsAccess.request()
        let contact = try store.unifiedContact(withIdentifier: id, keysToFetch: ContactOut.keys)
        emit(ContactOut(contact))
    }
}
