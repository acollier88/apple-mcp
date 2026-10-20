import Darwin
import Foundation
import XCTest
@testable import apple_tasks

final class SecretsTests: XCTestCase {
    private var previous: SecretStore!
    private var store: InMemorySecretStore!
    private var configDir: URL!

    override func setUpWithError() throws {
        previous = Secrets.store
        store = InMemorySecretStore()
        Secrets.store = store
        configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Secrets.store = previous
        previous = nil
        store = nil
        if let configDir {
            try? FileManager.default.removeItem(at: configDir)
        }
        configDir = nil
    }

    // MARK: - resolve

    func testResolveEnvWinsThenKeychainThenPlaintextThenNil() throws {
        try store.set("item", "from-keychain")

        let unique = "APPLE_TASKS_TEST_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        setenv(unique, "from-env", 1)
        defer { unsetenv(unique) }

        // ProcessInfo.environment is snapshotted on first access; setenv is
        // still the specified injection. If this process already cached env,
        // fall back to HOME which is always present and non-empty.
        let envName: String
        let envValue: String
        if let seen = ProcessInfo.processInfo.environment[unique], !seen.isEmpty {
            envName = unique
            envValue = seen
        } else {
            envName = "HOME"
            envValue = ProcessInfo.processInfo.environment["HOME"] ?? ""
            XCTAssertFalse(envValue.isEmpty, "HOME must be set")
        }

        let env = Secrets.resolve(env: envName, keychain: "item", plaintext: "from-file")
        XCTAssertEqual(env, Secrets.Resolved(value: envValue, source: .env))

        let kc = Secrets.resolve(env: unique + "_UNSET", keychain: "item", plaintext: "from-file")
        XCTAssertEqual(kc, Secrets.Resolved(value: "from-keychain", source: .keychain))

        let plain = Secrets.resolve(env: unique + "_UNSET", keychain: "missing", plaintext: "from-file")
        XCTAssertEqual(plain, Secrets.Resolved(value: "from-file", source: .plaintext))

        let missing = Secrets.resolve(env: unique + "_UNSET", keychain: "missing", plaintext: nil)
        XCTAssertNil(missing)
    }

    func testResolveSkipsEmptyEnvAndPlaintext() throws {
        try store.set("item", "from-keychain")

        let unique = "APPLE_TASKS_TEST_EMPTY_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        setenv(unique, "", 1)
        defer { unsetenv(unique) }

        if ProcessInfo.processInfo.environment[unique] != nil {
            let viaEmptyEnv = Secrets.resolve(env: unique, keychain: "item", plaintext: "from-file")
            XCTAssertEqual(viaEmptyEnv, Secrets.Resolved(value: "from-keychain", source: .keychain))
        }

        let emptyPlain = Secrets.resolve(env: unique + "_UNSET", keychain: "missing", plaintext: "")
        XCTAssertNil(emptyPlain)

        let emptyPlainOverKeychain = Secrets.resolve(env: unique + "_UNSET", keychain: "item", plaintext: "")
        XCTAssertEqual(emptyPlainOverKeychain, Secrets.Resolved(value: "from-keychain", source: .keychain))
    }

    // MARK: - InMemorySecretStore

    func testInMemoryGetSetRemoveList() throws {
        XCTAssertNil(try store.get("a"))
        XCTAssertEqual(try store.list(), [])

        try store.set("b", "two")
        try store.set("a", "one")
        XCTAssertEqual(try store.get("a"), "one")
        XCTAssertEqual(try store.list(), ["a", "b"])

        try store.set("a", "updated")
        XCTAssertEqual(try store.get("a"), "updated")

        XCTAssertTrue(try store.remove("a"))
        XCTAssertNil(try store.get("a"))
        XCTAssertFalse(try store.remove("a"))
        XCTAssertEqual(try store.list(), ["b"])
    }

    // MARK: - migrate plan / apply

    func testMigratePlanHasSixMoveSteps() throws {
        try writeFixtureFiles()
        let steps = try SecretCommand.plan(configDir: configDir, store: store)
        let moves = steps.filter { $0.action == "move" }
        XCTAssertEqual(moves.count, 6)

        let bySecret = Dictionary(uniqueKeysWithValues: moves.map { ($0.secret, $0) })
        XCTAssertEqual(bySecret[Secrets.ntfyTopic]?.field, "ntfy.topic")
        XCTAssertEqual(bySecret[Secrets.ntfyApprovalsReplyTopic]?.field, "approvalsReplyTopic")
        XCTAssertEqual(bySecret[Secrets.serveToken]?.field, "token")
        XCTAssertEqual(bySecret[Secrets.llmApiKey(profile: "local")]?.field, "profiles.local.apiKey")
        XCTAssertEqual(bySecret[Secrets.gmailClientSecret]?.field, "installed.client_secret")
        XCTAssertEqual(bySecret[Secrets.gmailToken]?.field, SecretCommand.wholeFileField)

        XCTAssertTrue(bySecret[Secrets.ntfyTopic]!.file.hasSuffix("/notify.json"))
        XCTAssertTrue(bySecret[Secrets.serveToken]!.file.hasSuffix("/serve.json"))
        XCTAssertTrue(bySecret[Secrets.llmApiKey(profile: "local")]!.file.hasSuffix("/llm.json"))
        XCTAssertTrue(bySecret[Secrets.gmailClientSecret]!.file.hasSuffix("/gmail/credentials.json"))
        XCTAssertTrue(bySecret[Secrets.gmailToken]!.file.hasSuffix("/gmail/token.json"))

        XCTAssertNil(bySecret[Secrets.llmApiKey(profile: "cloud")],
                     "profile without apiKey must not produce a move step")
    }

    func testMigrateApplyStoresStripsAndChmods() throws {
        try writeFixtureFiles()
        let steps = try SecretCommand.plan(configDir: configDir, store: store)
        _ = try SecretCommand.apply(steps, configDir: configDir, store: store)

        XCTAssertEqual(try store.get(Secrets.ntfyTopic), "my-topic")
        XCTAssertEqual(try store.get(Secrets.ntfyApprovalsReplyTopic), "my-reply")
        XCTAssertEqual(try store.get(Secrets.serveToken), "serve-secret")
        XCTAssertEqual(try store.get(Secrets.llmApiKey(profile: "local")), "sk-local")
        XCTAssertEqual(try store.get(Secrets.gmailClientSecret), "csecret")

        let storedToken = try store.get(Secrets.gmailToken)
        XCTAssertNotNil(storedToken)
        let tokenObj = try JSONSerialization.jsonObject(with: Data(storedToken!.utf8)) as? [String: Any]
        XCTAssertEqual(tokenObj?["accessToken"] as? String, "at")
        XCTAssertEqual(tokenObj?["refreshToken"] as? String, "rt")
        XCTAssertEqual((tokenObj?["expiresAt"] as? NSNumber)?.intValue, 1_234_567_890)

        let notify = try loadJSON(configDir.appendingPathComponent("notify.json"))
        XCTAssertNil((notify["ntfy"] as? [String: Any])?["topic"])
        XCTAssertNil(notify["approvalsReplyTopic"])
        XCTAssertEqual((notify["ntfy"] as? [String: Any])?["server"] as? String, "https://ntfy.sh")
        XCTAssertNotNil(notify["quietHours"])

        let serve = try loadJSON(configDir.appendingPathComponent("serve.json"))
        XCTAssertNil(serve["token"])
        XCTAssertEqual((serve["port"] as? NSNumber)?.intValue, 8745)
        XCTAssertEqual(serve["bind"] as? String, "loopback")

        let llm = try loadJSON(configDir.appendingPathComponent("llm.json"))
        let profiles = llm["profiles"] as? [String: Any]
        let local = profiles?["local"] as? [String: Any]
        XCTAssertNil(local?["apiKey"])
        XCTAssertEqual(local?["apiKeyKeychain"] as? String, "llm.local.apiKey")
        XCTAssertEqual(local?["endpoint"] as? String, "http://localhost:11434/v1")
        let cloud = profiles?["cloud"] as? [String: Any]
        XCTAssertNil(cloud?["apiKey"])
        XCTAssertNil(cloud?["apiKeyKeychain"])
        XCTAssertEqual(cloud?["apiKeyEnv"] as? String, "OPENAI_API_KEY")

        let creds = try loadJSON(configDir.appendingPathComponent("gmail/credentials.json"))
        let installed = creds["installed"] as? [String: Any]
        XCTAssertNil(installed?["client_secret"])
        XCTAssertEqual(installed?["client_id"] as? String, "cid")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: configDir.appendingPathComponent("gmail/token.json").path))

        for rel in ["notify.json", "serve.json", "llm.json", "gmail/credentials.json"] {
            let path = configDir.appendingPathComponent(rel).path
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            XCTAssertEqual(mode & 0o777, 0o600, "\(rel) should be 0600")
        }
    }

    func testMigratePlanIsIdempotentAfterApply() throws {
        try writeFixtureFiles()
        let first = try SecretCommand.plan(configDir: configDir, store: store)
        _ = try SecretCommand.apply(first, configDir: configDir, store: store)
        let second = try SecretCommand.plan(configDir: configDir, store: store)
        XCTAssertEqual(second, [], "plan must be empty after apply")
    }

    func testMigrateAlreadyInKeychainStillStripsPlaintext() throws {
        try store.set(Secrets.ntfyTopic, "already-stored")
        try writeJSON([
            "ntfy": ["topic": "file-topic", "server": "https://ntfy.sh"],
            "quietHours": ["notBetween": ["22:00", "07:00"]],
        ], to: configDir.appendingPathComponent("notify.json"))

        let steps = try SecretCommand.plan(configDir: configDir, store: store)
        let topic = steps.first { $0.secret == Secrets.ntfyTopic }
        XCTAssertEqual(topic?.action, "already-in-keychain")
        XCTAssertEqual(topic?.field, "ntfy.topic")

        _ = try SecretCommand.apply(steps, configDir: configDir, store: store)
        XCTAssertEqual(try store.get(Secrets.ntfyTopic), "already-stored")

        let notify = try loadJSON(configDir.appendingPathComponent("notify.json"))
        XCTAssertNil((notify["ntfy"] as? [String: Any])?["topic"])
        XCTAssertEqual((notify["ntfy"] as? [String: Any])?["server"] as? String, "https://ntfy.sh")
        XCTAssertNotNil(notify["quietHours"])
    }

    // MARK: - fixtures

    private func writeFixtureFiles() throws {
        try writeJSON([
            "ntfy": ["topic": "my-topic", "server": "https://ntfy.sh"],
            "quietHours": ["notBetween": ["22:00", "07:00"]],
            "approvalsReplyTopic": "my-reply",
        ], to: configDir.appendingPathComponent("notify.json"))

        try writeJSON([
            "token": "serve-secret",
            "port": 8745,
            "bind": "loopback",
        ], to: configDir.appendingPathComponent("serve.json"))

        try writeJSON([
            "default": "local",
            "profiles": [
                "local": [
                    "endpoint": "http://localhost:11434/v1",
                    "model": "llama",
                    "apiKey": "sk-local",
                ],
                "cloud": [
                    "endpoint": "https://api.example",
                    "model": "gpt",
                    "apiKeyEnv": "OPENAI_API_KEY",
                ],
            ],
        ], to: configDir.appendingPathComponent("llm.json"))

        let gmail = configDir.appendingPathComponent("gmail", isDirectory: true)
        try FileManager.default.createDirectory(at: gmail, withIntermediateDirectories: true)
        try writeJSON([
            "installed": [
                "client_id": "cid",
                "client_secret": "csecret",
                "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                "token_uri": "https://oauth2.googleapis.com/token",
            ],
        ], to: gmail.appendingPathComponent("credentials.json"))
        try writeJSON([
            "accessToken": "at",
            "refreshToken": "rt",
            "expiresAt": 1_234_567_890,
        ], to: gmail.appendingPathComponent("token.json"))
    }

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func loadJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            struct NotObject: Error {}
            throw NotObject()
        }
        return obj
    }
}
