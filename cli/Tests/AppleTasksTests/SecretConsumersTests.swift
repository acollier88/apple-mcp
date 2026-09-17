import Foundation
import XCTest
@testable import apple_tasks

final class SecretConsumersTests: XCTestCase {
    private var previousStore: SecretStore!
    private var tempDir: URL!
    private var savedEnv: [String: String?] = [:]

    private let envKeys = [
        Secrets.ntfyTopicEnv,
        Secrets.ntfyApprovalsReplyTopicEnv,
        Secrets.serveTokenEnv,
        Secrets.gmailClientSecretEnv,
    ]

    override func setUpWithError() throws {
        previousStore = Secrets.store
        Secrets.store = InMemorySecretStore()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-tasks-secrets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for key in envKeys {
            if let raw = getenv(key) {
                savedEnv[key] = String(cString: raw)
            } else {
                savedEnv[key] = nil
            }
            unsetenv(key)
        }
    }

    override func tearDownWithError() throws {
        Secrets.store = previousStore
        previousStore = nil
        for (key, value) in savedEnv {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        savedEnv.removeAll()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // MARK: - NotifyConfig resolvers

    func testResolveTopicPlaintext() {
        let config = NotifyConfig(
            ntfy: .init(topic: "file-topic", server: nil),
            quietHours: nil,
            approvalsReplyTopic: nil)
        let resolved = NotifyConfig.resolveTopic(config)
        XCTAssertEqual(resolved?.value, "file-topic")
        XCTAssertEqual(resolved?.source, .plaintext)
    }

    func testResolveTopicKeychainBeatsPlaintext() throws {
        try Secrets.store.set(Secrets.ntfyTopic, "kc-topic")
        let config = NotifyConfig(
            ntfy: .init(topic: "file-topic", server: nil),
            quietHours: nil,
            approvalsReplyTopic: nil)
        let resolved = NotifyConfig.resolveTopic(config)
        XCTAssertEqual(resolved?.value, "kc-topic")
        XCTAssertEqual(resolved?.source, .keychain)
    }

    func testResolveTopicEnvBeatsKeychain() throws {
        try Secrets.store.set(Secrets.ntfyTopic, "kc-topic")
        setenv(Secrets.ntfyTopicEnv, "env-topic", 1)
        defer { unsetenv(Secrets.ntfyTopicEnv) }
        let config = NotifyConfig(
            ntfy: .init(topic: "file-topic", server: nil),
            quietHours: nil,
            approvalsReplyTopic: nil)
        let resolved = NotifyConfig.resolveTopic(config)
        XCTAssertEqual(resolved?.value, "env-topic")
        XCTAssertEqual(resolved?.source, .env)
    }

    func testResolveTopicKeychainOnlyNoFile() throws {
        try Secrets.store.set(Secrets.ntfyTopic, "kc-only")
        let resolved = NotifyConfig.resolveTopic(nil)
        XCTAssertEqual(resolved?.value, "kc-only")
        XCTAssertEqual(resolved?.source, .keychain)
    }

    func testDerivedApprovalsReplyTopicInheritsSource() throws {
        try Secrets.store.set(Secrets.ntfyTopic, "kc-topic")
        let reply = NotifyConfig.resolveApprovalsReplyTopic(nil)
        XCTAssertEqual(reply?.value, "kc-topic-approvals")
        XCTAssertEqual(reply?.source, .keychain)
    }

    func testExplicitApprovalsReplyTopicBeatsDerived() {
        let config = NotifyConfig(
            ntfy: .init(topic: "file-topic", server: nil),
            quietHours: nil,
            approvalsReplyTopic: "custom-reply")
        let reply = NotifyConfig.resolveApprovalsReplyTopic(config)
        XCTAssertEqual(reply?.value, "custom-reply")
        XCTAssertEqual(reply?.source, .plaintext)
    }

    func testApprovalsReplyEnvBeatsDerived() {
        setenv(Secrets.ntfyApprovalsReplyTopicEnv, "env-reply", 1)
        defer { unsetenv(Secrets.ntfyApprovalsReplyTopicEnv) }
        let config = NotifyConfig(
            ntfy: .init(topic: "file-topic", server: nil),
            quietHours: nil,
            approvalsReplyTopic: "file-reply")
        let reply = NotifyConfig.resolveApprovalsReplyTopic(config)
        XCTAssertEqual(reply?.value, "env-reply")
        XCTAssertEqual(reply?.source, .env)
    }

    // MARK: - Doctor.secretsStatus

    func testSecretsStatusTempDirAndFixModes() throws {
        let notify = tempDir.appendingPathComponent("notify.json")
        try Data(#"{"ntfy":{"topic":"file-topic"}}"#.utf8).write(to: notify)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notify.path)

        try Data("""
        {
          "default": "keyed",
          "profiles": {
            "keyed": {"endpoint":"http://localhost/v1","model":"m","apiKey":"sk-not-reported"},
            "open": {"endpoint":"http://localhost/v1","model":"m"}
          }
        }
        """.utf8).write(to: tempDir.appendingPathComponent("llm.json"))

        try """
        # export SKIPPED=1
        export FOO=bar
        """.write(to: tempDir.appendingPathComponent("launchd.env"), atomically: true, encoding: .utf8)

        let store = InMemorySecretStore([Secrets.serveToken: "kc-serve-not-reported"])

        let before = Doctor.secretsStatus(
            configDir: tempDir, store: store, env: [:], fixModes: false)
        let byName = Dictionary(uniqueKeysWithValues: before.map { ($0.name, $0) })

        let topic = try XCTUnwrap(byName[Secrets.ntfyTopic])
        XCTAssertEqual(topic.source, SecretSource.plaintext.rawValue)
        XCTAssertEqual(topic.file, notify.path)
        XCTAssertEqual(topic.mode, "644")
        XCTAssertTrue(topic.note?.contains("mode 644, expected 600") == true,
                      "expected mode note, got \(topic.note ?? "nil")")
        XCTAssertTrue(topic.note?.contains("plaintext — move with: apple-tasks secret migrate --apply") == true)

        let serve = try XCTUnwrap(byName[Secrets.serveToken])
        XCTAssertEqual(serve.source, SecretSource.keychain.rawValue)
        XCTAssertNil(serve.file)
        XCTAssertNil(serve.mode)

        XCTAssertEqual(byName[Secrets.gmailClientSecret]?.source, SecretSource.missing.rawValue)
        XCTAssertEqual(byName[Secrets.gmailToken]?.source, SecretSource.missing.rawValue)
        XCTAssertNil(byName[Secrets.gmailClientSecret]?.file)

        let keyed = try XCTUnwrap(byName[Secrets.llmApiKey(profile: "keyed")])
        XCTAssertEqual(keyed.source, SecretSource.plaintext.rawValue)
        XCTAssertEqual(byName[Secrets.llmApiKey(profile: "open")]?.source, SecretSource.missing.rawValue)

        let launchd = try XCTUnwrap(byName["launchd.env:FOO"])
        XCTAssertEqual(launchd.source, SecretSource.plaintext.rawValue)
        XCTAssertNil(byName["launchd.env:SKIPPED"])

        let after = Doctor.secretsStatus(
            configDir: tempDir, store: store, env: [:], fixModes: true)
        let afterTopic = try XCTUnwrap(after.first { $0.name == Secrets.ntfyTopic })
        XCTAssertEqual(afterTopic.mode, "600")
        XCTAssertTrue(afterTopic.note?.contains("fixed to 600") == true,
                      "expected fixed note, got \(afterTopic.note ?? "nil")")
        let attrs = try FileManager.default.attributesOfItem(atPath: notify.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    // MARK: - Gmail Client decode

    func testGmailClientDecodesWithClientSecret() throws {
        let json = Data(#"{"client_id":"id","client_secret":"shh","auth_uri":"https://a","token_uri":"https://t"}"#.utf8)
        let client = try JSONDecoder().decode(GmailAuth.Client.self, from: json)
        XCTAssertEqual(client.clientId, "id")
        XCTAssertEqual(client.clientSecret, "shh")
    }

    func testGmailClientDecodesWithoutClientSecret() throws {
        let json = Data(#"{"client_id":"id","auth_uri":"https://a","token_uri":"https://t"}"#.utf8)
        let client = try JSONDecoder().decode(GmailAuth.Client.self, from: json)
        XCTAssertEqual(client.clientId, "id")
        XCTAssertNil(client.clientSecret)
    }
}
