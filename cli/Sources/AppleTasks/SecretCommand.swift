import ArgumentParser
import Darwin
import Foundation

struct SecretCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Keychain-backed secrets (service apple-tasks). Consumers resolve env → keychain → plaintext.",
        subcommands: [Set.self, Get.self, Rm.self, List.self, Migrate.self]
    )

    /// One planned (or applied) plaintext → Keychain move.
    struct MigrationStep: Codable, Equatable {
        let secret: String
        let file: String
        let field: String
        let action: String
    }

    static let wholeFileField = "(whole file)"

    static func resolvedConfigDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["APPLE_TASKS_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks", isDirectory: true)
    }

    /// Pure plan: inspect config files + store, never write.
    static func plan(configDir: URL, store: SecretStore) throws -> [MigrationStep] {
        var steps: [MigrationStep] = []

        let notifyURL = configDir.appendingPathComponent("notify.json")
        if let json = Self.loadDictionary(notifyURL) {
            if let ntfy = json["ntfy"] as? [String: Any],
               Self.nonEmptyString(ntfy["topic"]) != nil {
                steps.append(try Self.step(
                    secret: Secrets.ntfyTopic, file: notifyURL.path, field: "ntfy.topic",
                    store: store, plaintextPresent: true))
            }
            if Self.nonEmptyString(json["approvalsReplyTopic"]) != nil {
                steps.append(try Self.step(
                    secret: Secrets.ntfyApprovalsReplyTopic, file: notifyURL.path,
                    field: "approvalsReplyTopic", store: store, plaintextPresent: true))
            }
        }

        let serveURL = configDir.appendingPathComponent("serve.json")
        if let json = Self.loadDictionary(serveURL),
           Self.nonEmptyString(json["token"]) != nil {
            steps.append(try Self.step(
                secret: Secrets.serveToken, file: serveURL.path, field: "token",
                store: store, plaintextPresent: true))
        }

        let llmURL = configDir.appendingPathComponent("llm.json")
        if let json = Self.loadDictionary(llmURL),
           let profiles = json["profiles"] as? [String: Any] {
            for name in profiles.keys.sorted() {
                guard let profile = profiles[name] as? [String: Any],
                      Self.nonEmptyString(profile["apiKey"]) != nil else { continue }
                steps.append(try Self.step(
                    secret: Secrets.llmApiKey(profile: name),
                    file: llmURL.path,
                    field: "profiles.\(name).apiKey",
                    store: store, plaintextPresent: true))
            }
        }

        let credentialsURL = configDir.appendingPathComponent("gmail/credentials.json")
        if let json = Self.loadDictionary(credentialsURL) {
            if let installed = json["installed"] as? [String: Any],
               Self.nonEmptyString(installed["client_secret"]) != nil {
                steps.append(try Self.step(
                    secret: Secrets.gmailClientSecret, file: credentialsURL.path,
                    field: "installed.client_secret", store: store, plaintextPresent: true))
            } else if Self.nonEmptyString(json["client_secret"]) != nil {
                steps.append(try Self.step(
                    secret: Secrets.gmailClientSecret, file: credentialsURL.path,
                    field: "client_secret", store: store, plaintextPresent: true))
            }
        }

        let tokenURL = configDir.appendingPathComponent("gmail/token.json")
        if Self.compactJSON(at: tokenURL) != nil {
            steps.append(try Self.step(
                secret: Secrets.gmailToken, file: tokenURL.path,
                field: Self.wholeFileField, store: store, plaintextPresent: true))
        }

        return steps
    }

    /// Apply a plan: Keychain write then strip plaintext (or strip-only when already stored).
    static func apply(_ steps: [MigrationStep], configDir: URL, store: SecretStore) throws -> [MigrationStep] {
        _ = configDir
        for step in steps {
            switch step.action {
            case "move":
                let value = try Self.plaintextValue(step)
                try store.set(step.secret, value)
                try Self.strip(step)
            case "already-in-keychain":
                try Self.strip(step)
            default:
                break
            }
        }
        return steps
    }

    // MARK: - set

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Store a secret in the login Keychain. Value from --stdin or an interactive prompt; never as an argument."
        )

        @Argument(help: "Canonical secret name, e.g. ntfy.topic or llm.local.apiKey.")
        var name: String

        @Flag(name: .customLong("stdin"),
              help: "Read the value from stdin (one trailing newline trimmed).")
        var fromStdin = false

        func run() async throws {
            let value = try Self.readValue(name: name, fromStdin: fromStdin)
            guard !value.isEmpty else {
                throw AppleTasksError.invalidInput("secret '\(name)' value is empty")
            }
            try Secrets.store.set(name, value)
            AuditDB.shared.record(command: "secret set", detail: name)
            emit(SetOut(name: name, stored: true))
        }

        struct SetOut: Codable {
            let name: String
            let stored: Bool
        }

        static func readValue(name: String, fromStdin: Bool) throws -> String {
            if fromStdin {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                return SecretCommand.trimOneTrailingNewline(raw)
            }
            if isatty(STDIN_FILENO) != 0 {
                return try SecretCommand.promptSecret(name: name)
            }
            throw AppleTasksError.invalidInput(
                "pass --stdin to read the secret from a pipe, or run in a terminal for a prompt")
        }
    }

    // MARK: - get

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Print a secret's value (for shell substitution). --quiet exits 0/1 by presence."
        )

        @Argument(help: "Canonical secret name.")
        var name: String

        @Flag(help: "Print nothing; exit 0 if present, 1 if missing.")
        var quiet = false

        func run() async throws {
            AuditDB.shared.record(command: "secret get", detail: name)
            let value = try Secrets.store.get(name)
            guard let value, !value.isEmpty else {
                if quiet { throw ExitCode(1) }
                fputs("secret '\(name)' not found\n", stderr)
                throw ExitCode(1)
            }
            if quiet { return }
            print(value)
        }
    }

    // MARK: - rm

    struct Rm: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Delete a secret from the login Keychain."
        )

        @Argument(help: "Canonical secret name.")
        var name: String

        func run() async throws {
            let removed = try Secrets.store.remove(name)
            AuditDB.shared.record(command: "secret rm", detail: name)
            emit(RmOut(name: name, removed: removed))
        }

        struct RmOut: Codable {
            let name: String
            let removed: Bool
        }
    }

    // MARK: - list

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List Keychain item names (accounts) for service apple-tasks. Never values."
        )

        func run() async throws {
            let names = try Secrets.store.list()
            emit(ListOut(service: KeychainSecretStore.service, names: names))
        }

        struct ListOut: Codable {
            let service: String
            let names: [String]
        }
    }

    // MARK: - migrate

    struct Migrate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "migrate",
            abstract: "Move plaintext secrets from config files into the Keychain. Default is a dry run."
        )

        @Flag(name: .customLong("apply"),
              help: "Write Keychain items and strip plaintext from config files. Default is dry-run.")
        var shouldApply = false

        func run() async throws {
            let configDir = SecretCommand.resolvedConfigDir()
            let steps = try SecretCommand.plan(configDir: configDir, store: Secrets.store)
            if shouldApply {
                _ = try SecretCommand.apply(steps, configDir: configDir, store: Secrets.store)
                AuditDB.shared.record(
                    command: "secret migrate",
                    detail: steps.map(\.secret).joined(separator: ","))
            }
            emit(MigrateOut(applied: shouldApply, steps: steps))
        }

        struct MigrateOut: Codable {
            let applied: Bool
            let steps: [MigrationStep]
        }
    }

    // MARK: - helpers

    static func trimOneTrailingNewline(_ s: String) -> String {
        if s.hasSuffix("\r\n") { return String(s.dropLast(2)) }
        if s.hasSuffix("\n") || s.hasSuffix("\r") { return String(s.dropLast()) }
        return s
    }

    static func promptSecret(name: String) throws -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        defer {
            for i in buf.indices { buf[i] = 0 }
        }
        let prompt = "\(name): "
        guard readpassphrase(prompt, &buf, buf.count, 0) != nil else {
            throw AppleTasksError.invalidInput("could not read secret '\(name)'")
        }
        fputs("\n", stderr)
        return String(cString: buf)
    }

    private static func step(secret: String, file: String, field: String,
                             store: SecretStore, plaintextPresent: Bool) throws -> MigrationStep {
        let action: String
        if !plaintextPresent {
            action = "nothing-to-move"
        } else if let existing = try store.get(secret), !existing.isEmpty {
            action = "already-in-keychain"
        } else {
            action = "move"
        }
        return MigrationStep(secret: secret, file: file, field: field, action: action)
    }

    private static func loadDictionary(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func compactJSON(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(obj),
              let compact = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: compact, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    private static func plaintextValue(_ step: MigrationStep) throws -> String {
        let url = URL(fileURLWithPath: step.file)
        if step.field == wholeFileField {
            guard let text = compactJSON(at: url) else {
                throw AppleTasksError.saveFailed("could not read '\(step.file)' for \(step.secret)")
            }
            return text
        }
        guard let json = loadDictionary(url),
              let value = string(at: step.field, in: json), !value.isEmpty else {
            throw AppleTasksError.saveFailed("missing \(step.field) in '\(step.file)'")
        }
        return value
    }

    private static func string(at field: String, in json: [String: Any]) -> String? {
        var current: Any = json
        for key in field.split(separator: ".").map(String.init) {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current as? String
    }

    private static func strip(_ step: MigrationStep) throws {
        let url = URL(fileURLWithPath: step.file)
        if step.field == wholeFileField {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        guard var json = loadDictionary(url) else {
            throw AppleTasksError.saveFailed("could not rewrite '\(step.file)'")
        }
        removePath(step.field.split(separator: ".").map(String.init), from: &json)
        if step.field.hasPrefix("profiles."), step.field.hasSuffix(".apiKey") {
            let parts = step.field.split(separator: ".").map(String.init)
            // profiles.<name>.apiKey → profiles.<name>.apiKeyKeychain
            if parts.count >= 3 {
                let profileName = parts[1]
                setPath(["profiles", profileName, "apiKeyKeychain"], value: step.secret, on: &json)
            }
        }
        try writeJSON(json, to: url)
    }

    private static func removePath(_ parts: [String], from dict: inout [String: Any]) {
        guard let key = parts.first else { return }
        if parts.count == 1 {
            dict.removeValue(forKey: key)
            return
        }
        guard var child = dict[key] as? [String: Any] else { return }
        removePath(Array(parts.dropFirst()), from: &child)
        dict[key] = child
    }

    private static func setPath(_ parts: [String], value: Any, on dict: inout [String: Any]) {
        guard let key = parts.first else { return }
        if parts.count == 1 {
            dict[key] = value
            return
        }
        var child = dict[key] as? [String: Any] ?? [:]
        setPath(Array(parts.dropFirst()), value: value, on: &child)
        dict[key] = child
    }

    private static func writeJSON(_ json: [String: Any], to url: URL) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw AppleTasksError.saveFailed("could not encode '\(url.path)': \(error.localizedDescription)")
        }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw AppleTasksError.saveFailed("could not write '\(url.path)': \(error.localizedDescription)")
        }
    }
}
