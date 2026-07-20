import ArgumentParser
import CryptoKit
import Darwin
import Foundation

// IDEAS #42: Gmail as a first-class capture feed. The official Google MCP
// servers are pull-tools for agents; this is the watermarked scan side,
// mirroring mail_scan's shape so triage treats both mailboxes the same.
// Read-only scope, no send path — replies stay in the [google] agent lane.

struct GmailHeaderOut: Codable {
    let id: String
    let threadId: String
    let subject: String
    let from: String
    let received: String
    let read: Bool
    let snippet: String
}

struct GmailMessageOut: Codable {
    let id: String
    let threadId: String
    let subject: String
    let from: String
    let received: String
    let read: Bool
    let body: String
}

struct Gmail: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watermarked Gmail inbox capture via the Gmail API (read-only scope; no send path).",
        subcommands: [GmailScan.self, GmailShow.self, GmailLogin.self],
        defaultSubcommand: GmailScan.self
    )
}

// MARK: - OAuth client + token storage

enum GmailAuth {
    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/apple-tasks/gmail")
    }
    static var credentialsURL: URL { configDir.appendingPathComponent("credentials.json") }
    static var tokenURL: URL { configDir.appendingPathComponent("token.json") }

    static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    struct Client: Codable {
        let clientId: String
        let clientSecret: String
        let authUri: String
        let tokenUri: String

        enum CodingKeys: String, CodingKey {
            case clientId = "client_id", clientSecret = "client_secret"
            case authUri = "auth_uri", tokenUri = "token_uri"
        }
    }

    struct Token: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double
    }

    static func loadClient() throws -> Client {
        guard let data = try? Data(contentsOf: credentialsURL) else {
            throw AppleTasksError.invalidInput("""
            no Gmail OAuth client at \(credentialsURL.path). One-time setup: \
            create a Google Cloud project, enable the Gmail API, configure the \
            OAuth consent screen (External, yourself as test user), create an \
            OAuth client ID of type "Desktop app", and save the downloaded \
            JSON to that path. Then run 'apple-tasks gmail login'.
            """)
        }
        // Google's download wraps the client under "installed" (Desktop app).
        struct Wrapper: Codable { let installed: Client? }
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data), let client = wrapped.installed {
            return client
        }
        if let client = try? JSONDecoder().decode(Client.self, from: data) {
            return client
        }
        throw AppleTasksError.invalidInput(
            "could not parse \(credentialsURL.path) — expected the JSON downloaded for a \"Desktop app\" OAuth client")
    }

    static func loadToken() throws -> Token {
        guard let data = try? Data(contentsOf: tokenURL),
              let token = try? JSONDecoder().decode(Token.self, from: data) else {
            throw AppleTasksError.invalidInput(
                "no Gmail session at \(tokenURL.path) — run 'apple-tasks gmail login' once from a terminal")
        }
        return token
    }

    static func save(_ token: Token) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(token)
        try data.write(to: tokenURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    }

    /// A valid access token, refreshing (and re-saving — Google rotates) when expired.
    static func accessToken() async throws -> String {
        var token = try loadToken()
        if token.expiresAt > Date().timeIntervalSince1970 + 60 {
            return token.accessToken
        }
        let client = try loadClient()
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
        ]
        let (data, status) = try await postForm(url: client.tokenUri, form: form)
        struct Refresh: Codable { let access_token: String; let expires_in: Double }
        guard status == 200, let refreshed = try? JSONDecoder().decode(Refresh.self, from: data) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AppleTasksError.automationFailed("""
            Gmail token refresh failed (\(detail.prefix(200))). Run 'apple-tasks \
            gmail login' again. Note: while the OAuth consent screen is in \
            "Testing" status Google expires refresh tokens after 7 days — \
            publish the app to "In production" (staying unverified is fine for \
            personal use) for a token that persists.
            """)
        }
        token.accessToken = refreshed.access_token
        token.expiresAt = Date().timeIntervalSince1970 + refreshed.expires_in
        try save(token)
        return token.accessToken
    }

    static func postForm(url: String, form: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\(urlEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func get(_ url: String, bearer: String) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Login (interactive; PKCE + loopback redirect)

struct GmailLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "One-time browser consent for read-only Gmail access. Opens a browser; run from a terminal, not via MCP."
    )

    struct Out: Codable {
        let loggedIn: Bool
        let tokenPath: String
    }

    func run() async throws {
        // A human must click the consent screen; an agent kicking this off
        // just throws a surprise browser window at the user.
        guard ProcessInfo.processInfo.environment["APPLE_TASKS_CALLER"] != "mcp" else {
            throw AppleTasksError.invalidInput("gmail login is interactive; run it from a terminal, never via MCP")
        }
        let client = try GmailAuth.loadClient()

        // Loopback listener on an ephemeral port (Google requires loopback
        // redirects for Desktop clients; the port is free-form).
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppleTasksError.automationFailed("could not create loopback socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            throw AppleTasksError.automationFailed("could not listen on 127.0.0.1")
        }
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)
        let redirect = "http://127.0.0.1:\(port)"

        let verifier = GmailAuth.base64url(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        let challenge = GmailAuth.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = GmailAuth.base64url(Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))

        var parts = URLComponents(string: client.authUri)!
        parts.queryItems = [
            .init(name: "client_id", value: client.clientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GmailAuth.scope),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        let authURL = parts.url!
        FileHandle.standardError.write(Data("Opening browser for Google consent (waiting up to 3 minutes)…\n".utf8))
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = [authURL.absoluteString]
        try? opener.run()

        var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pollFd, 1, 180_000) > 0 else {
            throw AppleTasksError.automationFailed("timed out waiting for the browser consent redirect")
        }
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { throw AppleTasksError.automationFailed("loopback accept failed") }
        defer { close(conn) }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = read(conn, &buffer, buffer.count)
        let request = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n" +
            "<html><body style=\"font-family:sans-serif\"><h3>apple-tasks is connected to Gmail.</h3>You can close this tab.</body></html>"
        _ = reply.withCString { write(conn, $0, strlen($0)) }

        guard let lineEnd = request.firstIndex(of: "\r"),
              let path = request[..<lineEnd].split(separator: " ").dropFirst().first,
              let query = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems,
              query.first(where: { $0.name == "state" })?.value == state,
              let code = query.first(where: { $0.name == "code" })?.value else {
            let err = URLComponents(string: "http://127.0.0.1\(request.split(separator: " ").dropFirst().first ?? "/")")?
                .queryItems?.first(where: { $0.name == "error" })?.value
            throw AppleTasksError.automationFailed("consent redirect had no code\(err.map { " (\($0))" } ?? "")")
        }

        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
            "redirect_uri": redirect,
            "code_verifier": verifier,
        ]
        let (data, status) = try await GmailAuth.postForm(url: client.tokenUri, form: form)
        struct Grant: Codable { let access_token: String; let refresh_token: String?; let expires_in: Double }
        guard status == 200, let grant = try? JSONDecoder().decode(Grant.self, from: data) else {
            throw AppleTasksError.automationFailed(
                "token exchange failed: \((String(data: data, encoding: .utf8) ?? "").prefix(300))")
        }
        guard let refresh = grant.refresh_token else {
            throw AppleTasksError.automationFailed(
                "Google returned no refresh token — revoke apple-tasks at myaccount.google.com/permissions and log in again")
        }
        try GmailAuth.save(.init(accessToken: grant.access_token, refreshToken: refresh,
                                 expiresAt: Date().timeIntervalSince1970 + grant.expires_in))
        AuditDB.shared.record(command: "gmail login", detail: "read-only OAuth session saved")
        emit(Out(loggedIn: true, tokenPath: GmailAuth.tokenURL.path))
    }
}

// MARK: - Scan (watermarked capture feed)

struct GmailScan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: """
        List inbox messages newer than the last scan (watermarked; first run \
        looks back 24h). Headers + snippet only; use 'gmail show' for a body. \
        If more than --limit messages arrived since the last scan, the \
        overflow beyond the newest --limit is skipped.
        """
    )

    @Option(help: "Maximum messages to return, newest first (default 50).")
    var limit: Int = 50

    @Option(help: "Extra Gmail search terms ANDed with the watermark (e.g. 'from:boss@example.com').")
    var query: String?

    struct MessageMeta: Codable {
        let id: String
        let threadId: String
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String
        let payload: Payload?
        struct Payload: Codable {
            let headers: [Header]?
            struct Header: Codable { let name: String; let value: String }
        }
    }

    static func header(_ meta: MessageMeta, _ name: String) -> String {
        meta.payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    func run() async throws {
        let bearer = try await GmailAuth.accessToken()
        var state = ScanState.load()
        let watermarkMs = state.gmailScanWatermark.flatMap(Double.init)
            ?? (Date().timeIntervalSince1970 - 86_400) * 1000

        // Gmail's after: is second-granular; the strict ms filter below
        // drops boundary messages already seen last scan.
        var q = "in:inbox after:\(Int(watermarkMs / 1000))"
        if let query { q += " \(query)" }
        let listURL = "https://gmail.googleapis.com/gmail/v1/users/me/messages" +
            "?q=\(GmailAuth.urlEncode(q))&maxResults=\(max(1, min(limit, 500)))"
        let (listData, listStatus) = try await GmailAuth.get(listURL, bearer: bearer)
        guard listStatus == 200 else {
            throw AppleTasksError.automationFailed(
                "Gmail list failed (\(listStatus)): \((String(data: listData, encoding: .utf8) ?? "").prefix(300))")
        }
        struct List: Codable {
            let messages: [Ref]?
            struct Ref: Codable { let id: String }
        }
        let refs = (try JSONDecoder().decode(List.self, from: listData)).messages ?? []

        var rows: [GmailHeaderOut] = []
        var newWatermark = watermarkMs
        let iso = ISO8601DateFormatter()
        for ref in refs {
            let metaURL = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(ref.id)" +
                "?format=metadata&metadataHeaders=Subject&metadataHeaders=From"
            let (metaData, metaStatus) = try await GmailAuth.get(metaURL, bearer: bearer)
            guard metaStatus == 200,
                  let meta = try? JSONDecoder().decode(MessageMeta.self, from: metaData),
                  let ms = Double(meta.internalDate) else { continue }
            guard ms > watermarkMs else { continue }
            newWatermark = max(newWatermark, ms)
            rows.append(GmailHeaderOut(
                id: meta.id, threadId: meta.threadId,
                subject: Self.header(meta, "Subject"),
                from: Self.header(meta, "From"),
                received: iso.string(from: Date(timeIntervalSince1970: ms / 1000)),
                read: !(meta.labelIds ?? []).contains("UNREAD"),
                snippet: meta.snippet ?? ""))
        }
        rows.sort { $0.received > $1.received }

        state.gmailScanWatermark = String(Int(newWatermark))
        try state.save()
        emit(rows)
    }
}

// MARK: - Show (one message body)

struct GmailShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one Gmail message including its plain-text body."
    )

    @Argument(help: "Message id from 'gmail scan'.")
    var id: String

    @Option(name: .customLong("max-chars"), help: "Truncate the body to this many characters (default 4000).")
    var maxChars: Int = 4000

    struct FullMessage: Codable {
        let id: String
        let threadId: String
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String
        let payload: Part?
        struct Part: Codable {
            let mimeType: String?
            let headers: [GmailScan.MessageMeta.Payload.Header]?
            let body: Body?
            let parts: [Part]?
            struct Body: Codable { let data: String? }
        }
    }

    /// Depth-first search for the first part of the wanted MIME type.
    static func findPart(_ part: FullMessage.Part?, mimeType: String) -> String? {
        guard let part else { return nil }
        if part.mimeType == mimeType, let data = part.body?.data { return data }
        for child in part.parts ?? [] {
            if let found = findPart(child, mimeType: mimeType) { return found }
        }
        return nil
    }

    static func decodeBase64URL(_ s: String) -> String? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func run() async throws {
        let bearer = try await GmailAuth.accessToken()
        let url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(GmailAuth.urlEncode(id))?format=full"
        let (data, status) = try await GmailAuth.get(url, bearer: bearer)
        guard status != 404 else { throw AppleTasksError.taskNotFound(id) }
        guard status == 200, let message = try? JSONDecoder().decode(FullMessage.self, from: data) else {
            throw AppleTasksError.automationFailed(
                "Gmail get failed (\(status)): \((String(data: data, encoding: .utf8) ?? "").prefix(300))")
        }
        let plain = Self.findPart(message.payload, mimeType: "text/plain").flatMap(Self.decodeBase64URL)
        let body = plain ?? message.snippet ?? ""
        let ms = Double(message.internalDate) ?? 0
        let subject = message.payload.map { part in
            part.headers?.first { $0.name.caseInsensitiveCompare("Subject") == .orderedSame }?.value ?? ""
        } ?? ""
        let from = message.payload.map { part in
            part.headers?.first { $0.name.caseInsensitiveCompare("From") == .orderedSame }?.value ?? ""
        } ?? ""
        emit(GmailMessageOut(
            id: message.id, threadId: message.threadId,
            subject: subject, from: from,
            received: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000)),
            read: !(message.labelIds ?? []).contains("UNREAD"),
            body: String(body.prefix(maxChars))))
    }
}
