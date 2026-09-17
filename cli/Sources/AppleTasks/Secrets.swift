import Foundation
import Security

// P7 secrets hardening (docs/security.md §3, §7). Secrets can live in the
// login Keychain under service "apple-tasks"; every consumer resolves
// env → keychain → plaintext → missing. Plaintext keeps working, `doctor`
// reports where each secret actually came from. Nothing here is exposed
// over MCP or HTTP.

/// Where a resolved secret came from. `doctor.secrets` reports this per secret.
enum SecretSource: String, Codable, Sendable {
    case env, keychain, plaintext, missing
}

/// Backing store for named secrets. `KeychainSecretStore` is the real one;
/// `InMemorySecretStore` is for tests (never touch the login Keychain in CI).
protocol SecretStore: Sendable {
    func get(_ name: String) throws -> String?
    func set(_ name: String, _ value: String) throws
    /// True when an item existed and was removed.
    @discardableResult
    func remove(_ name: String) throws -> Bool
    /// Item names (accounts) under the service, sorted.
    func list() throws -> [String]
}

/// Login-keychain generic-password items: service `apple-tasks`, account =
/// secret name. File-based (login) keychain on purpose so a launchd job can
/// read after login; `kSecAttrAccessible*` only applies to the
/// data-protection keychain and is deliberately not set.
struct KeychainSecretStore: SecretStore {
    static let service = "apple-tasks"
    let service: String

    init(service: String = KeychainSecretStore.service) {
        self.service = service
    }

    private func baseQuery(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    func get(_ name: String) throws -> String? {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw AppleTasksError.saveFailed("keychain read '\(name)' failed: \(Self.describe(status))")
        }
    }

    func set(_ name: String, _ value: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(name) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw AppleTasksError.saveFailed("keychain update '\(name)' failed: \(Self.describe(status))")
        }
        var add = baseQuery(name)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "apple-tasks: \(name)"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AppleTasksError.saveFailed("keychain add '\(name)' failed: \(Self.describe(addStatus))")
        }
    }

    @discardableResult
    func remove(_ name: String) throws -> Bool {
        let status = SecItemDelete(baseQuery(name) as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default:
            throw AppleTasksError.saveFailed("keychain delete '\(name)' failed: \(Self.describe(status))")
        }
    }

    func list() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            let items = out as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
        case errSecItemNotFound:
            return []
        default:
            throw AppleTasksError.saveFailed("keychain list failed: \(Self.describe(status))")
        }
    }

    static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "OSStatus \(status)"
    }
}

/// Test double. Not thread-safe beyond a lock; fine for XCTest.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String]
    private let lock = NSLock()

    init(_ initial: [String: String] = [:]) {
        values = initial
    }

    func get(_ name: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[name]
    }

    func set(_ name: String, _ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[name] = value
    }

    @discardableResult
    func remove(_ name: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return values.removeValue(forKey: name) != nil
    }

    func list() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.sorted()
    }
}

enum Secrets {
    /// Process-wide store. Tests swap in `InMemorySecretStore`.
    nonisolated(unsafe) static var store: SecretStore = KeychainSecretStore()

    // Canonical item names (Keychain account). Consumers and `doctor` share these.
    static let ntfyTopic = "ntfy.topic"
    static let ntfyApprovalsReplyTopic = "ntfy.approvalsReplyTopic"
    static let serveToken = "serve.token"
    static let gmailClientSecret = "gmail.clientSecret"
    /// JSON blob of `GmailAuth.Token` (access + refresh + expiry).
    static let gmailToken = "gmail.token"
    static func llmApiKey(profile: String) -> String { "llm.\(profile).apiKey" }

    /// Env var names consumers check before the Keychain.
    static let ntfyTopicEnv = "APPLE_TASKS_NTFY_TOPIC"
    static let ntfyApprovalsReplyTopicEnv = "APPLE_TASKS_NTFY_APPROVALS_TOPIC"
    static let serveTokenEnv = "APPLE_TASKS_SERVE_TOKEN"
    static let gmailClientSecretEnv = "APPLE_TASKS_GMAIL_CLIENT_SECRET"

    struct Resolved: Equatable, Sendable {
        let value: String
        let source: SecretSource
    }

    /// env var (when `envName` is set and the variable is non-empty) →
    /// keychain item (when `itemName` is set and present) → non-empty
    /// plaintext → nil. Keychain errors are swallowed here (treated as
    /// absent) so a locked/denied keychain degrades to plaintext, not a crash.
    static func resolve(env envName: String?, keychain itemName: String?,
                        plaintext: String?) -> Resolved? {
        if let envName, !envName.isEmpty,
           let value = ProcessInfo.processInfo.environment[envName], !value.isEmpty {
            return Resolved(value: value, source: .env)
        }
        if let itemName, let value = keychainValue(itemName) {
            return Resolved(value: value, source: .keychain)
        }
        if let plaintext, !plaintext.isEmpty {
            return Resolved(value: plaintext, source: .plaintext)
        }
        return nil
    }

    /// Keychain read that never throws — nil when missing or on any error.
    static func keychainValue(_ name: String) -> String? {
        guard let value = try? store.get(name), !value.isEmpty else { return nil }
        return value
    }
}
